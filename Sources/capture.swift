@preconcurrency import ScreenCaptureKit
import Accelerate

let RESET_CURSOR : String = "\u{001B}[H"

class Capture: NSObject, SCStreamDelegate, SCStreamOutput {

    private var Configuration : SCStreamConfiguration?
    private var Filter        : SCContentFilter?
    private var Stream        : SCStream?

    private var OutputText : String = "┃"

    private var FixedSizeFlag : Bool = false
    private var Width  : Int = 0
    private var Height : Int = 0

    private var PreviousHeights : [Int]?

    private let MIN_DECIBALS : Float
    private let MAX_DECIBALS : Float

    init(outputText char : String?, fixedSize dimensions : (Int,Int)?)
    {
        if let char = char {OutputText = char}

        if let dimensions = dimensions
        {
            FixedSizeFlag = true
            Width = dimensions.0
            Height = dimensions.1
        }

        MIN_DECIBALS = 0.0
        MAX_DECIBALS = 60.0

        super.init()
    }

    @MainActor
    func configureCapture(showApplications show_applications : Bool, includedApplications apps : [String]) async throws
    {
        let Content : SCShareableContent = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )

        guard let Display : SCDisplay = Content.displays.first else{return}
        let Applications  : [SCRunningApplication] = Content.applications

        if show_applications
        {
            var Names : [String] = []
            for application in Applications
            {
                let AppName = application.applicationName
                if AppName.count > 0 {Names.append(AppName)}
            }
            Names.sort()
            for name in Names {print(name)}
            exit(0)
        }
        else
        {
            if apps.count > 0
            {
                var IncludedApplications : [SCRunningApplication] = []
                for application in Applications
                {
                    let AppName = application.applicationName.lowercased()
                    if apps.contains(AppName)
                    {IncludedApplications.append(application)}
                }
                Filter = SCContentFilter(display: Display, including: IncludedApplications, exceptingWindows: [])
            }
            else
            {
                Filter = SCContentFilter(display: Display, excludingWindows: [])
            }
        }

        Configuration = SCStreamConfiguration()
        if let Configuration = Configuration
        {
            Configuration.capturesAudio = true
            Configuration.minimumFrameInterval = CMTime(value : 1, timescale : CMTimeScale.max)
            Configuration.width = 2
            Configuration.height = 2
        }
    }

    @MainActor
    func startCapture() async throws
    {
        if let Filter = Filter, let Configuration = Configuration
        {
            Stream = SCStream(filter: Filter, configuration: Configuration, delegate: self)
            try Stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
            try await Stream?.startCapture()
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error)
    {
        print("Stream stopped with error")
        exit(1)
    }

    func stream(_ output: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
    {
        if type == .audio
        {
            guard let Samples : AVAudioPCMBuffer = sampleBuffer.asPCMBuffer else{return}

            let ChannelCount : Int = Int(Samples.format.channelCount)
            let FrameLength  : Int = Int(Samples.frameLength)

            guard let ChannelData = Samples.floatChannelData else{return}

            for channel in 0..<ChannelCount
            {
                let ChannelSamples : UnsafeMutablePointer<Float> = ChannelData[channel]
                let Floats : [Float] = Array(UnsafeBufferPointer(start: ChannelSamples, count: FrameLength))

                // Getting next power of 2
                // Horribly inefficient
                var fftLength : Int = Floats.count
                while fftLength & (fftLength - 1) != 0 {fftLength += 1}

                var Real      : [Float] = [Float](repeating: 0.0, count: fftLength)
                var Imaginary : [Float] = [Float](repeating: 0.0, count: fftLength)

                for i: Int in 0..<Floats.count / 2 {Real[i] = Floats[i]}

                let log2n    : vDSP_Length = vDSP_Length(log2(Float(fftLength)))
                let fftSetup : FFTSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))!

                Real.withUnsafeMutableBufferPointer { RealBuffer in
                    Imaginary.withUnsafeMutableBufferPointer { ImaginaryBuffer in

                        var SplitComplex : DSPSplitComplex = DSPSplitComplex(
                            realp: RealBuffer.baseAddress!,
                            imagp: ImaginaryBuffer.baseAddress!
                        )

                        vDSP_fft_zrip(fftSetup, &SplitComplex, 1, log2n, FFTDirection(FFT_FORWARD))
                        vDSP_destroy_fftsetup(fftSetup)

                        let Half : Int = fftLength / 2
                        var Magnitudes: [Float] = [Float](repeating: 0, count: Half)
                        for i : Int in 0..<Half
                        {
                            let RV : Float = RealBuffer[i]
                            let IV : Float = ImaginaryBuffer[i]
                            Magnitudes[i] = sqrt(RV*RV + IV*IV)
                        }

                        if !FixedSizeFlag
                        {
                            guard let (Columns,Rows) = getTerminalSize() else{return}
                            Width = Columns
                            Height = Rows
                        }
                        let fWidth : Float = Float(Width)

                        let UniqueBinCount  : Int = Magnitudes.count / 2
                        let fUniqueBinCount : Float = Float(UniqueBinCount)

                        var Decibals : [Float] = []

                        for i : Int in 0..<Width
                        {
                            let Start : Int = Int(Float(i) * fUniqueBinCount / fWidth)
                            let End   : Int = min(Int(Float(i + 1) * fUniqueBinCount / fWidth), UniqueBinCount)

                            if Start >= End {continue}

                            let slice            : ArraySlice<Float> = Magnitudes[Start..<End]
                            let AverageMagnitude : Float = slice.reduce(0, +) / Float(End-Start)
                            let AverageDB        : Float = max(20 * log10(AverageMagnitude),0.0)

                            Decibals.append(AverageDB / MAX_DECIBALS)
                        }

                        self.output(Decibals,Height)

                    }
                }
            }
        }
    }

    private func getTerminalSize() -> (COLUMNS : Int, ROWS : Int)?
    {
        var w = winsize()
        if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
            let c : Int = Int(w.ws_col)
            let r : Int = Int(w.ws_row)
            return (c,r)
        }
        return nil
    }

    // TODO
    // Fix the rows / height debacle
    // function accepts a rows argument but I could just manually access the private var height
    // which is the same thing
    private func output(_ decibals : [Float], _ rows : Int)
    {
        var TempArray : [Int] = []

        let OutputHeight : Float = Float(rows)
        var Output : String = RESET_CURSOR

        for height : Int in stride(from: rows - 1, through: 0, by: -1)
        {
            for (i,bar) in decibals.enumerated()
            {
                let RelativeHeight : Int = Int(((OutputHeight)*bar).rounded())

                // Smooth the visualizer to reduce flickering effect
                if let PreviousHeights = PreviousHeights, PreviousHeights[i] > RelativeHeight
                {
                    let SmoothenedHeight = max(PreviousHeights[i]-1, 0)
                    Output.append(SmoothenedHeight >= height ? OutputText : " ")
                    TempArray.append(SmoothenedHeight)
                }
                else
                {
                    Output.append(RelativeHeight >= height ? OutputText : " ")
                    TempArray.append(RelativeHeight)
                }

            }
            Output.append("\n")
        }
        PreviousHeights = TempArray

        Output.removeLast()
        print(Output,terminator: "")
    }

}

// https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}