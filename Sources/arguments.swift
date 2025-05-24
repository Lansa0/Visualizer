import ArgumentParser

@MainActor
enum Args
{
    static var ShowApplications     : Bool = false
    static var IncludedApplications : [String] = []

    static var FontColour : String?
    static var OutputText : String?
    static var AudioRange : (Int,Int)?
    static var FixedSize  : (Int,Int)?

    static var ExperimentalMode : Arguments.Experimental?
}

// ignore warning
// idk why i have to deal with @MainActor b.s when this isn't using any UI
struct Arguments : @preconcurrency ParsableCommand
{

    @Flag(
        name: [.customShort("l"), .customLong("application-list")],
        help: ArgumentHelp(
            "List of all running applications",
            discussion: """
            Use this list to find the appropriate names to filter which applications will be recorded

            """
        )
    )
    var application_list : Bool = false

    @Option(
        name: [.short, .customLong("app")],
        help: ArgumentHelp(
            "The name of the application included to be recoreded",
            discussion: """
            Adding an application that isn't currently running will not be recorded
            The input name of the application is not case-sensitive, however it can't assume spelling
            If an application has a space in its name, wrap the input in quotes ("<Application Name>")
            More than one application can be added

            """
        )
    )
    var apps : [String] = []

    @Option(
        name: [.short, .customLong("colour")],
        help: ArgumentHelp(
            "Colour of the visualizer",
            discussion: """
            Defaults to running terminal settings

            Supports the codes 16-231 in the standard terminal 256-colour palette
            Must be in the format <r>,<g>,<b> where each value is in the range 0-255 inclusive
            (i.e 255,255,255)

            """
        )
    )
    var colour : String?

    @Option(
        name: [.short, .customLong("text")],
        help: ArgumentHelp(
            "The text character used for visualization",
            discussion: """
            Defaults to "┃"

            Must be one character long, else will fall to default value
            Some characters may not display properly

            """
        )
    )
    var text : String?

    @Option(
        name: [.short, .customLong("range")],
        parsing: .unconditional,
        help: ArgumentHelp(
            "Sets decibal range",
            discussion: """
            Defaults to 0-60

            Must be in the format <Lower>,<Upper> (i.e 0,60)
            Invalid range will fall to default

            """
        )
    )
    var range : String?


    @Option(
        name: [.short, .customLong("size")],
        help: ArgumentHelp(
            "Sets fixed visualizer size",
            discussion: """
            Default nature of this program dynamically sizes the visualizer based on the terminal, passing a fixed size will change this behaviour

            Must be in the format <Width>x<Height> (i.e 80x24)

            """
        )
    )
    var size : String?

    enum Experimental : EnumerableFlag
    {
        case rainbow
    }

    @Flag(
        help: ArgumentHelp(
            "Set visualizer to one of the experimental modes",
            discussion: """
            May be highly buggy and not compatible with other commands

            """
        )
    )
    var experimental : Experimental?

    @MainActor
    mutating func run() throws
    {
        Args.ShowApplications = application_list

        for app in apps
        {
            Args.IncludedApplications.append(app.lowercased())
        }

        if let colour = colour
        {
            let Componenets : [String.SubSequence] = colour.split(separator: ",", maxSplits: 3)
            let Red   : Int? = Int(Componenets[0])
            let Green : Int? = Int(Componenets[1])
            let Blue  : Int? = Int(Componenets[2])

            // checks if r,g,b values exist and within range
            if var r = Red, 0 <= r && r <= 255, var g = Green, 0 <= g && g <= 255, var b = Blue, 0 <= b && b <= 255
            {
                r = Int(Double(r) / 255.0 * 5.0 + 0.5)
                g = Int(Double(g) / 255.0 * 5.0 + 0.5)
                b = Int(Double(b) / 255.0 * 5.0 + 0.5)

                let Code = 16 + (36 * r) + (6 * g) + b

                Args.FontColour = "\u{001B}[38;5;\(Code)m"
            }
        }

        if let text = text, text.count == 1
        {
            Args.OutputText = text
        }

        if let range = range
        {
            let Bounds : [String.SubSequence] = range.split(separator: ",", maxSplits: 2)
            let Lower : Int? = Int(Bounds[0])
            let Upper : Int? = Int(Bounds[1])

            if let L = Lower, let U = Upper
            {
                Args.AudioRange = (L,U)
            }
        }

        if let size = size
        {
            let Dimensions : [String.SubSequence] = size.split(separator: "x", maxSplits: 2)
            let Width  : Int? = Int(Dimensions[0])
            let Height : Int? = Int(Dimensions[1])

            if let Width = Width, let Height = Height 
            {
                Args.FixedSize = (Width,Height)
            }
        }

        if let experimental = experimental
        {
            Args.ExperimentalMode = experimental
        }

    }

}