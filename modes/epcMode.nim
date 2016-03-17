import tables, net, parseopt2, strutils, parseutils, os, sequtils, rdstdin
import ../nimsuggest, ../sexp, commonMode

# Do NOT import suggest. It will lead to wierd bugs with
# suggestionResultHook, because suggest.nim is included by sigmatch.
# So we import that one instead.
import compiler/options, compiler/commands, compiler/modules, compiler/sem,
  compiler/passes, compiler/passaux, compiler/msgs, compiler/nimconf,
  compiler/extccomp, compiler/condsyms, compiler/lists,
  compiler/sigmatch, compiler/ast


const epcModeHelpMsg = """
Nimsuggest EPC Mode Switches:
  -p, --port:port_no     Port to use to connect (defaults to 8000).
  --address:"address"    Address to bind to. Defaults to ""
"""


type
  EpcModeData* = ref object of BaseModeData
    serverPort: Port
    address: string
    persist: bool

  EUnexpectedCommand = object of Exception


# ModeData Interface Methods
proc initEpcModeData*(cmdline: CmdLineData): EpcModeData =
  new(result)
  result.projectPath = cmdline.projectPath
  result.serverPort = Port(0)
  result.address = ""

  for switch in cmdline.modeSwitches:
    case switch.kind
    of cmdLongOption, cmdShortOption:
      case switch.key.normalize
      of "p", "port":
        try:
          result.serverPort = Port(parseInt(switch.value))
        except ValueError:
          quit("Invalid port:'" & switch.value & "'")
      of "address":
        result.address = switch.value
      else:
        quit("Invalid mode switch '$#'" % [switch.key])
    else:
      discard

proc echoEpcModeOptions*() =
  echo(epcModeHelpMsg)

proc sexp(s: IdeCmd): SexpNode = sexp($s)

proc sexp(s: TSymKind): SexpNode = sexp($s)

proc sexp(s: Suggest): SexpNode =
  # If you change the oder here, make sure to change it over in
  # nim-mode.el too.
  result = convertSexp([
    s.section, s.symkind, s.qualifiedPath.map(newSString), s.filePath,
    s.forth, s.line, s.column, s.doc
  ])

proc sexp(s: seq[Suggest]): SexpNode =
  result = newSList()
  for sug in s:
    result.add(sexp(sug))

proc listEPC(): SexpNode =
  let
    argspecs = sexp("file line column dirtyfile".split(" ").map(newSSymbol))
    docstring = sexp("line starts at 1, column at 0, dirtyfile is optional")
  result = newSList()
  for command in ["sug", "con", "def", "use", "dus"]:
    let
      cmd = sexp(command)
      methodDesc = newSList()
    methodDesc.add(cmd)
    methodDesc.add(argspecs)
    methodDesc.add(docstring)
    result.add(methodDesc)

proc executeEPC(cmd: IdeCmd, args: SexpNode) =
  let
    file = args[0].getStr
    line = args[1].getNum
    column = args[2].getNum
  var dirtyfile = ""
  if len(args) > 3:
    dirtyfile = args[3].getStr(nil)
  execute(cmd, file, dirtyfile, int(line), int(column))

proc returnEPC(socket: var Socket, uid: BiggestInt, s: SexpNode,
               return_symbol = "return") =
  let response = $convertSexp([newSSymbol(return_symbol), uid, s])
  socket.send(toHex(len(response), 6))
  socket.send(response)

template checkSanity(client, sizeHex, size, messageBuffer: typed) =
  if client.recv(sizeHex, 6) != 6:
    raise newException(ValueError, "didn't get all the hexbytes")
  if parseHex(sizeHex, size) == 0:
    raise newException(ValueError, "invalid size hex: " & $sizeHex)
  if client.recv(messageBuffer, size) != size:
    raise newException(ValueError, "didn't get all the bytes")

proc mainCommand*(data: EpcModeData) =
  var
    client = newSocket()
    server = newSocket()

   # Setup server socket
  server.bindaddr(Port(0), data.address)
  let (_, serverPort) = server.getLocalAddr()
  server.listen()
  echo serverPort

  # Wait for connection
  accept(server, client)
  while true:
    var
      sizeHex = ""
      size = 0
      messageBuffer = ""

    checkSanity(client, sizeHex, size, messageBuffer)

    let
      message = parseSexp($messageBuffer)
      messageType = message[0].getSymbol
    case messageType:
    of "call":
      var results: seq[Suggest] = @[]
      suggestionResultHook = proc (s: Suggest) =
        results.add(s)

      let
        uid = message[1].getNum
        cmd = parseIdeCmd(message[2].getSymbol)
        args = message[3]
      executeEPC(cmd, args)
      returnEPC(client, uid, sexp(results))
    of "return":
      raise newException(EUnexpectedCommand, "no return expected")
    of "return-error":
      raise newException(EUnexpectedCommand, "no return expected")
    of "epc-error":
      stderr.writeline("recieved epc error: " & $messageBuffer)
      raise newException(IOError, "epc error")
    of "methods":
      returnEPC(client, message[1].getNum, listEPC())
    else:
      raise newException(EUnexpectedCommand, "unexpected call: " & messageType)