open Belt

module Error = Connection__Emacs__Error
module Scheduler = Connection__Scheduler
module Process = LanguageServerMule.Client.Process

module ProcInfo: {
  type t = {
    path: string,
    args: array<string>,
    version: string,
  }
  let make: (string, array<string>) => Promise.t<result<t, Error.t>>
  let toString: t => string
} = {
  type t = {
    path: string,
    args: array<string>,
    version: string,
  }

  @module external untildify: string => string = "untildify"

  // a more sophiscated "make"
  let make = (path, args): Promise.t<result<t, Error.t>> => {
    // normailize the path by replacing the tild "~/" with the absolute path of home directory
    let path = untildify(path)

    let process = Process.make(path, ["-V"])
    let (promise, resolve) = Promise.pending()

    let handle = process->Process.onOutput(output =>
      switch output {
      | Process.Stdout(output) =>
        switch Js.String.match_(%re("/Agda version (.*)/"), output) {
        | None => resolve(Error("Cannot read Agda version"))
        | Some(match_) =>
          switch match_[1] {
          | None => resolve(Error("Cannot read Agda version"))
          | Some(version) =>
            resolve(
              Ok({
                path: path,
                args: args,
                version: version,
              }),
            )
          }
        }
      | Process.Stderr(err) =>
        resolve(Error("Message from stderr when validating the program:\n" ++ err))
      | Process.Event(e) =>
        resolve(
          Error("Something occured when validating the program:\n" ++ Process.Event.toString(e)),
        )
      }
    )
    promise->Promise.tap(_ => handle())->Promise.mapError(e => Error.Validation(e))
  }

  // for making error report
  let toString = self => {
    let path = "* path: " ++ self.path
    let args = "* args: " ++ Util.Pretty.array(self.args)
    let version = "* version: " ++ self.version
    let os = "* platform: " ++ N.OS.type_()

    "## Parse Log" ++
    ("\n" ++
    (path ++ ("\n" ++ (args ++ ("\n" ++ (version ++ ("\n" ++ (os ++ "\n"))))))))
  }
}

module type Module = {
  type t
  // lifecycle
  let make: LanguageServerMule.Method.t => Promise.t<result<t, Error.t>>
  let destroy: t => Promise.t<unit>
  // messaging
  let sendRequest: (
    t,
    string,
    result<Response.t, Error.t> => Promise.t<unit>,
  ) => Promise.t<result<unit, Error.t>>
  let getInfo: t => (string, string) // version and path
}

module Module: Module = {
  type t = {
    procInfo: ProcInfo.t,
    process: Process.t,
    chan: Chan.t<result<Parser.Incr.Gen.t<Response.Prioritized.t>, Error.t>>,
    mutable encountedFirstPrompt: bool,
  }

  let destroy = self => {
    self.chan->Chan.destroy
    self.encountedFirstPrompt = false
    self.process->Process.destroy
  }

  let wire = (self): unit => {
    // We use the prompt "Agda2>" as the delimiter of the end of a response
    // However, the prompt "Agda2>" also appears at the very start of the conversation
    // So this would be what it looks like:
    //    >>> request
    //      stop          <------- wierd stop
    //      yield
    //      yield
    //      stop
    //    >> request
    //      yield
    //      yield
    //      stop
    let toResponse = Parser.Incr.Gen.flatMap(x =>
      switch x {
      | Error((no, e)) => Parser.Incr.Gen.Yield(Error(Parser.Error.SExpression(no, e)))
      | Ok(Parser.SExpression.A("Agda2>")) => Parser.Incr.Gen.Stop
      | Ok(tokens) => Parser.Incr.Gen.Yield(Response.Prioritized.parse(tokens))
      }
    )

    // resolves the requests in the queue
    let handleResponse = (res: Parser.Incr.Gen.t<result<Response.Prioritized.t, Parser.Error.t>>) =>
      switch res {
      | Yield(Ok(response)) => self.chan->Chan.emit(Ok(Yield(response)))
      | Yield(Error(parseError)) => self.chan->Chan.emit(Error(ResponseParseError(parseError)))
      | Stop =>
        if self.encountedFirstPrompt {
          self.chan->Chan.emit(Ok(Stop))
        } else {
          // do nothing when encountering the first Stop
          self.encountedFirstPrompt = true
        }
      }

    // incremental S-expression
    let incrParser = Parser.SExpression.makeIncr(x => x->toResponse->handleResponse)

    // listens to the "data" event on the stdout
    // The chunk may contain various fractions of the Agda output
    // TODO: handle the `listenerHandle`
    let listenerHandle = ref(None)

    listenerHandle :=
      Process.onOutput(self.process, x =>
        switch x {
        | Stdout(rawText) =>
          // sometimes Agda would return error messages from STDOUT
          if Js.String.startsWith("Error:", rawText) {
            self.chan->Chan.emit(Error(AgdaError(rawText)))
          } else {
            // split the raw text into pieces and feed it to the parser
            rawText->Parser.split->Array.forEach(Parser.Incr.feed(incrParser))
          }
        | Stderr(_) => ()
        | Event(e) => self.chan->Chan.emit(Error(Process(e)))
        }
      )->Some
  }

  let make = method =>
    switch method {
    | LanguageServerMule.Method.ViaTCP(_) =>
      Promise.resolved(Error(Error.ConnectionViaTCPNotSupported))
    | ViaCommand(path, _, _, _) =>
      // Js.Array.concat([1, 2, 3], [4, 5, 6]) == [4, 5, 6, 1, 2, 3], fuck me right?
      let args = Js.Array.concat(Config.Connection.getCommandLineOptions(), ["--interaction"])

      ProcInfo.make(path, args)
      ->Promise.mapOk(procInfo => {
        procInfo: procInfo,
        process: Process.make(procInfo.path, procInfo.args),
        chan: Chan.make(),
        encountedFirstPrompt: false,
      })
      ->Promise.tapOk(wire)
    }

  let onResponse = (conn, callback) => {
    let scheduler = Scheduler.make()
    // this promise get resolved after all Responses has been received from Agda
    let (responsePromise, stopResponseListener) = Promise.pending()

    // There are 2 kinds of Responses
    //  NonLast Response :
    //    * get handled first
    //    * don't invoke `sendAgdaRequest`
    //  Last Response :
    //    * have priorities, those with the smallest priority number are executed first
    //    * only get handled:
    //        1. after prompt has reappeared
    //        2. after all NonLast Responses
    //        3. after all interactive highlighting is complete
    //    * may invoke `sendAgdaRequest`
    let listener: result<Parser.Incr.Gen.t<Response.Prioritized.t>, Error.t> => unit = x =>
      switch x {
      | Error(error) =>
        // stop the Agda Response listener
        stopResponseListener(Error(error))
        callback(Error(error))->ignore
      | Ok(Yield(NonLast(response))) =>
        scheduler->Scheduler.runNonLast(response => callback(Ok(response)), response)
      | Ok(Yield(Last(priority, response))) => scheduler->Scheduler.addLast(priority, response)
      | Ok(Stop) =>
        // stop the Agda Response listener
        stopResponseListener(Ok())
        // start handling Last Responses, after all NonLast Responses have been handled
        scheduler
        ->Scheduler.runLast(response => {
          callback(Ok(response))
          // resolve the `responseHandlingPromise` after all Last Responses have been handled
        })
      }

    // start listening for responses
    let listenerHandle = ref(None)
    listenerHandle := Some(conn.chan->Chan.on(listener))
    // destroy the listener after all responses have been received
    responsePromise
    ->Promise.tap(_ =>
      listenerHandle.contents->Option.forEach(destroyListener => destroyListener())
    )
  }

  let sendRequest = (conn, request, handler): Promise.promise<Promise.result<unit, Error.t>> => {
    // this promise gets resolved after all Responses have been received and handled
    let promise = onResponse(conn, handler)
    Process.send(conn.process, request)->ignore
    promise
  }

  let getInfo = conn => (conn.procInfo.version, conn.procInfo.path)
}

include Module
