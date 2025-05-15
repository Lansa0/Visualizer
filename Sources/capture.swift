@preconcurrency import ScreenCaptureKit
import Accelerate

let RESET_CURSOR : String = "\u{001B}[H"

class Capture: NSObject, SCStreamDelegate, SCStreamOutput {

    private var Stream : SCStream?

    private var OutputText : String = "|"

    private var FixedSizeFlag : Bool = false
    private var Width  : Int = 0
    private var Height : Int = 0

    private let MAX_DECIBALS : Float = 60.0

    init(outputText c : String?, fixedSize s : (Int,Int)?)
    {
        if let c = c {OutputText = c}

        if let s = s
        {
            FixedSizeFlag = true
            Width = s.0
            Height = s.1
        }

        super.init()
    }

    @MainActor
    func startCapture() async throws
    {
        let Content : SCShareableContent = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let Display : SCDisplay = Content.displays.first else{return}

        let Filter : SCContentFilter = SCContentFilter(display: Display, excludingWindows: [])

        let Configuration : SCStreamConfiguration = SCStreamConfiguration()
        Configuration.capturesAudio = true
        Configuration.minimumFrameInterval = CMTime(value : 1, timescale : CMTimeScale.max)
        Configuration.width = 2
        Configuration.height = 2

        Stream = SCStream(filter: Filter, configuration: Configuration, delegate: self)
        try Stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try await Stream?.startCapture()
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
            guard let Samples: AVAudioPCMBuffer = sampleBuffer.asPCMBuffer else{return}

            let channelCount = Int(Samples.format.channelCount)
            let frameLength = Int(Samples.frameLength)

            guard let channelData = Samples.floatChannelData else{return}

            for channel in 0..<channelCount {
                let channelSamples : UnsafeMutablePointer<Float> = channelData[channel]
                let Floats : [Float] = Array(UnsafeBufferPointer(start: channelSamples, count: frameLength))

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
                        for i: Int in 0..<Half
                        {
                            let RV : Float = RealBuffer[i]
                            let IV : Float = ImaginaryBuffer[i]
                            Magnitudes[i] = sqrt(RV*RV + IV*IV)
                        }

                        if !FixedSizeFlag 
                        {
                            guard let (Columns,Rows) = getTerminalSize() else{return}
                            Width = Columns; Height = Rows
                        }

                        let UniqueBinCount : Int = Magnitudes.count / 2
                        var Decibals : [Float] = []

                        for i : Int in 0..<Width
                        {
                            let Start : Float = Float(i) * Float(UniqueBinCount) / Float(Width)
                            let End   : Float = Float(i + 1) * Float(UniqueBinCount) / Float(Width)

                            let StartBin : Int = Int(Start)
                            let EndBin   : Int = min(Int(End), UniqueBinCount)

                            if StartBin >= EndBin {continue}

                            let slice : ArraySlice<Float> = Magnitudes[StartBin..<EndBin]
                            let AverageMagnitude : Float = slice.reduce(0, +) / Float(slice.count)
                            let AverageDB : Float = max(20 * log10(AverageMagnitude),0.0)

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

    private func output(_ decibals : [Float], _ rows : Int)
    {
        let OutputHeight : Float = Float(rows)
        var Output : String = RESET_CURSOR

        for height : Int in stride(from: Int(OutputHeight) - 1, through: 0, by: -1)
        {
            for (_,bar) in decibals.enumerated()
            {
                let RelativeHeight: Int = Int(((OutputHeight)*bar).rounded())
                Output.append(RelativeHeight >= height ? OutputText : " ")
            }
            Output.append("\n")
        }
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