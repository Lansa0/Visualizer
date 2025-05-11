import ScreenCaptureKit
import Accelerate
import CoreMedia

class Capture: NSObject, SCStreamDelegate, SCStreamOutput {

    var Stream : SCStream?

    func startCapture() async throws
    {
        let Content : SCShareableContent = try await SCShareableContent.excludingDesktopWindows(
            true,
            onScreenWindowsOnly: true
        )
        guard let Display : SCDisplay = Content.displays.first else{return}

        let Filter : SCContentFilter = SCContentFilter(display: Display, excludingWindows: [])

        let Configuration : SCStreamConfiguration = SCStreamConfiguration()
        Configuration.capturesAudio = true                                        // Defaults to stereo and 48kHz
        Configuration.minimumFrameInterval = CMTime(value : 100, timescale : 100) // 1 Frame per 100 seconds (assuming this helps performance)
        Configuration.width = 2                                                   // very low resolution
        Configuration.height = 2

        Stream = SCStream(filter: Filter, configuration: Configuration, delegate: self)

        try Stream?.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())
        try await Stream?.startCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) 
    {
        print("Stream stopped w/ error")
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

                        let NumberOfBars : Int = 80

                        let UniqueBinCount : Int = Magnitudes.count / 2
                        var Decibals : [Float] = []

                        for i : Int in 0..<NumberOfBars
                        {
                            let Start : Float = Float(i) * Float(UniqueBinCount) / Float(NumberOfBars)
                            let End   : Float = Float(i + 1) * Float(UniqueBinCount) / Float(NumberOfBars)

                            let StartBin : Int = Int(Start)
                            let EndBin   : Int = min(Int(End), UniqueBinCount)

                            if StartBin >= EndBin {continue}

                            let slice : ArraySlice<Float> = Magnitudes[StartBin..<EndBin]
                            let AverageMagnitude : Float = slice.reduce(0, +) / Float(slice.count)

                            let AverageDB : Float = max(20 * log10(AverageMagnitude),0.0)

                            Decibals.append(AverageDB / 40)
                        }

                        self.output(Decibals)

                    }
                }
            }
        }
    }

    private func output(_ decibals : [Float])
    {
        let MAXHEIGHT : Float = 24.0 - 1.0
        var Output : String = "\u{001B}[H" // place cursor top-left

        for height : Int in stride(from: Int(MAXHEIGHT) - 1, through: 0, by: -1)
        {
            for (_,bar) in decibals.enumerated()
            {
                let RelativeHeight: Int = Int(((MAXHEIGHT)*bar).rounded())
                Output.append(RelativeHeight >= height ? "|" : " ")
            }
            Output.append("\n")
        }
        Output.removeLast()
        print(Output)
    }

}

// https://developer.apple.com/documentation/screencapturekit/capturing_screen_content_in_macos
// For Sonoma updated to https://developer.apple.com/forums/thread/727709
extension CMSampleBuffer {
    var asPCMBuffer: AVAudioPCMBuffer? {
        try? self.withAudioBufferList { audioBufferList, _ -> AVAudioPCMBuffer? in
            guard let absd = self.formatDescription?.audioStreamBasicDescription else { return nil }
            guard let format = AVAudioFormat(standardFormatWithSampleRate: absd.mSampleRate, channels: absd.mChannelsPerFrame) else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: audioBufferList.unsafePointer)
        }
    }
}

print("\u{1b}[H\u{1b}[2J")
let C : Capture = Capture()
Task {try await C.startCapture()}
RunLoop.main.run()