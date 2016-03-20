# - docker run -v "$(pwd):/project" -w /project yglukhov/devel nimble build
echo "test started at " & staticExec("date")

template p(s: string, body: typed) =
  echo s
  body
  echo s & "done"

p("nimble build"):
  exec "nimble build"

p("help command"):
  # Just make sure whether it can executable or not
  exec "./nimsuggest --help"
  exec "./nimsuggest --h"
  exec "./nimsuggest -h"

p("version"):
  exec "./nimsuggest --version"

p("EPC"):
  var epcPort = staticExec "./nimsuggest --epc nimsuggest.nim.cfg &"
  echo epcPort
