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
        guard let Display : SCDisplay = Content.displays.first else {return}

        let Filter : SCContentFilter = SCContentFilter(
            display: Display,
            excludingWindows: []
        )

        let Configuration : SCStreamConfiguration = SCStreamConfiguration()
        Configuration.capturesAudio = true                                      // Defaults to stereo and 48kHz
        Configuration.minimumFrameInterval = CMTime(value : 100, timescale : 1) // 1 Frame per 100 seconds (assuming this helps performance)
        Configuration.width = 874                                               // 480p resolution
        Configuration.height = 480

        Stream = SCStream(
            filter: Filter,
            configuration: Configuration,
            delegate: self
        )

        try Stream?.addStreamOutput(
            self,
            type: .audio,
            sampleHandlerQueue: DispatchQueue(label: "audioQueue")
        )

        try await Stream?.startCapture()
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) 
    {
        print("Stream stopped w/ error")
        exit(1)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType)
    {
        if type == .audio
        {
            if let BlockBuffer: CMBlockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer)
            {
                var TotalLength : Int = 0
                var DataPointer : UnsafeMutablePointer<CChar>?

                CMBlockBufferGetDataPointer(
                    BlockBuffer,
                    atOffset : 0,
                    lengthAtOffsetOut : nil,
                    totalLengthOut: &TotalLength,
                    dataPointerOut: &DataPointer
                )

                if let DataPointer : UnsafeMutablePointer<CChar> = DataPointer
                {
                    let Count : Int = TotalLength/2

                    let RawPointer : UnsafeMutableRawPointer = UnsafeMutableRawPointer(DataPointer)
                    let pcmData    : UnsafeMutablePointer<Int16> = RawPointer.bindMemory(to: Int16.self, capacity: Count)

                    let Floats : [Float] = Array(UnsafeBufferPointer(start: pcmData, count: Count)).map {Float($0) / 32768.0}

                    let fftLength : Int = 4096

                    var Real      : [Float] = [Float](repeating: 0.0, count: fftLength)
                    var Imaginary : [Float] = [Float](repeating: 0.0, count: fftLength)

                    for i: Int in 0 ..< Count {Real[i] = Floats[i]}

                    let log2n : vDSP_Length = vDSP_Length(log2(Float(fftLength)))
                    let fftSetup : FFTSetup = vDSP_create_fftsetup(log2n, Int32(kFFTRadix2))!
                    defer {vDSP_destroy_fftsetup(fftSetup)}

                    Real.withUnsafeMutableBufferPointer { RealBuffer in
                        Imaginary.withUnsafeMutableBufferPointer { ImaginaryBuffer in

                            var splitComplex : DSPSplitComplex = DSPSplitComplex(
                                realp: RealBuffer.baseAddress!,
                                imagp: ImaginaryBuffer.baseAddress!
                            )

                            vDSP_fft_zrip(
                                fftSetup,
                                &splitComplex,
                                1,
                                log2n,
                                Int32(FFT_FORWARD)
                            )

                            let Half: Int = fftLength / 2
                            var Magnitudes: [Float] = [Float](repeating: 0, count: Half)
                            for i: Int in 0..<Half 
                            {
                                let RealValue: Float = RealBuffer[i]
                                let ImaginaryValue: Float = ImaginaryBuffer[i]
                                Magnitudes[i] = sqrt(RealValue*RealValue + ImaginaryValue*ImaginaryValue)
                            }

                            let NumberOfBars : Int = 80
                            let MaxHeight : Float = 24.0

                            let uniqueBinCount : Int = Magnitudes.count / 2
                            var Bars : [Float] = []

                            for i : Int in 0..<NumberOfBars
                            {
                                let Start : Float = Float(i) * Float(uniqueBinCount) / Float(NumberOfBars)
                                let End   : Float = Float(i + 1) * Float(uniqueBinCount) / Float(NumberOfBars)

                                let StartBin : Int = Int(Start)
                                let EndBin   : Int = min(Int(End), uniqueBinCount)

                                if StartBin >= EndBin {continue}

                                let slice : ArraySlice<Float> = Magnitudes[StartBin..<EndBin]
                                let AverageMagnitude : Float = slice.reduce(0, +) / Float(slice.count)

                                Bars.append(AverageMagnitude)
                            }

                            if let maxMagnitude = Bars.max(), maxMagnitude > 0
                            {
                                Bars = Bars.map { $0 / maxMagnitude }
                            }

                            print("\u{1b}[H\u{1b}[2J") // Clear display

                            for Height : Int in stride(from: Int(MaxHeight) - 1, through: 0, by: -1)
                            {
                                var Line : String = ""

                                for (_,Bar) in Bars.enumerated()
                                {
                                    let BarHeight : Int = Int((MaxHeight*Bar).rounded())

                                    Line += BarHeight >= Height ? "|" : " "
                                }
                                print(Line)
                            }
                        }
                    }
                }
            }
        }
    }
}

let C : Capture = Capture()
Task {try await C.startCapture()}
RunLoop.main.run()