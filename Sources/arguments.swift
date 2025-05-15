import ArgumentParser

let COLOUR_MAP : [String:String] = [
    "black"   : "\u{001B}[0;30m",
    "blue"    : "\u{001B}[0;34m",
    "cyan"    : "\u{001B}[0;36m",
    "green"   : "\u{001B}[0;32m",
    "magenta" : "\u{001B}[0;35m",
    "red"     : "\u{001B}[0;31m",
    "white"   : "\u{001B}[0;37m",
    "yellow"  : "\u{001B}[0;33m"
]

@MainActor
final class Args
{
    static var FontColour : String?
    static var OutputText : String?
    static var FixedSize  : (Int,Int)?
}

struct Arguments : @preconcurrency ParsableCommand
{
    @Option(
        name: [.short, .customLong("colour")],
        help: ArgumentHelp(
            "Colour of the visualizer",
            discussion: """
            Defaults to terminal default font colour
            Valid Options:
                    - black
                    - blue
                    - cyan
                    - green
                    - magenta
                    - red
                    - white
                    - yellow

            """
        )
    )
    var colour : String?

    @Option(
        name: [.short,.customLong("text")],
        help: ArgumentHelp(
            "The text character used for visualization",
            discussion: """
            Defaults to "|"
            Must be one character long, else will default
            Some characters may not display properly

            """
        )
    )
    var text : String = "|"

    @Option(
        name: [.short,.customLong("size")],
        help: ArgumentHelp(
            "Sets fixed visualizer size",
            discussion: """
            Default nature of this program dynamically sizes the visualizer based on the terminal,
            passing a fixed size will change this behaviour

            Must be in the format <Width>x<Height> (i.e 80x24)

            """
        )
    )
    var size : String?

    @MainActor
    mutating  func run() throws
    {
        if let colour = colour, COLOUR_MAP[colour.lowercased()] != nil
        {
            Args.FontColour = COLOUR_MAP[colour.lowercased()]!
        }

        if text.count == 1 {Args.OutputText = text}

        if let size = size
        {
            let S : [String.SubSequence] = size.split(separator: "x",maxSplits: 2)
            let Width  : Int? = Int(S[0])
            let Height : Int? = Int(S[1])

            if let Width = Width, let Height = Height 
            {
                Args.FixedSize = (Width,Height)
            }
        }
    }

}