@preconcurrency import ScreenCaptureKit
import Accelerate

let RESET_CURSOR : String = "\u{001B}[H"

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

private func nextPower2(_ n : Int) -> Int
{
    var x = n-1
    x |= x >> 1
    x |= x >> 2
    x |= x >> 4
    x |= x >> 8
    x |= x >> 16
    return x+1
}


class Capture: NSObject, SCStreamDelegate, SCStreamOutput {

    private var Configuration : SCStreamConfiguration?
    private var Filter        : SCContentFilter?
    private var Stream        : SCStream?

    private let OutputText : String

    private let FixedSizeFlag : Bool
    private var Width  : Int = 0
    private var Height : Int = 0

    private var PreviousHeights : [Int]?

    private let MIN_DECIBALS : Float
    private let MAX_DECIBALS : Float

    init(outputText char : String?, fixedSize dimensions : (Int,Int)?, audioRange range : (Int,Int)?)
    {
        if let char = char 
        {
            OutputText = char
        } 
        else
        {
            OutputText = "┃"
        }

        if let dimensions = dimensions
        {
            FixedSizeFlag = true
            Width = dimensions.0
            Height = dimensions.1
        }
        else
        {
            FixedSizeFlag = false
        }

        if let range = range
        {
            MIN_DECIBALS = Float(range.0)
            MAX_DECIBALS = Float(range.1)
        }
        else
        {
            MIN_DECIBALS = 0.0
            MAX_DECIBALS = 60.0
        }

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

                let fftLength : Int = nextPower2(Floats.count)

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
                            let AverageDB        : Float = max(20 * log10(AverageMagnitude),MIN_DECIBALS) - MIN_DECIBALS

                            let RANGE = MAX_DECIBALS - MIN_DECIBALS
                            Decibals.append(AverageDB / RANGE)
                        }

                        self.output(Decibals)

                    }
                }
            }
        }
    }

    private func output(_ decibals : [Float])
    {
        var TempArray : [Int] = []

        let fHeight : Float = Float(Height)
        var Output : String = RESET_CURSOR

        for height : Int in stride(from: Height - 1, through: 0, by: -1)
        {
            for (i,bar) in decibals.enumerated()
            {
                let RelativeHeight : Int = Int(((fHeight)*bar).rounded())

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