import CoreMedia

let CLEAR_SCREEN : String = "\u{1b}[H\u{1b}[2J"
let HIDE_CURSOR  : String = "\u{001B}[?25l"
let SHOW_CURSOR  : String = "\u{001B}[?25h"
let SET_DEFAULT  : String = "\u{001B}[0;0m"

Arguments.main()

// https://stackoverflow.com/a/45714258
signal(SIGINT, SIG_IGN) 
let sigintSrc = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
sigintSrc.setEventHandler {
    print(SHOW_CURSOR,SET_DEFAULT)
    exit(0)
}
sigintSrc.resume()

print(CLEAR_SCREEN,HIDE_CURSOR)
if let FontColour = Args.FontColour {print(FontColour)}

let C : Capture = Capture(outputText : Args.OutputText, fixedSize : Args.FixedSize)
Task{try await C.startCapture()}
RunLoop.main.run()