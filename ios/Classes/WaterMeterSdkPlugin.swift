import Flutter
import UIKit
import Vision

public class WaterMeterSdkPlugin: NSObject, FlutterPlugin {
  public static func register(with registrar: FlutterPluginRegistrar) {
    let channel = FlutterMethodChannel(name: "water_meter_sdk", binaryMessenger: registrar.messenger())
    let instance = WaterMeterSdkPlugin()
    registrar.addMethodCallDelegate(instance, channel: channel)
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "getPlatformVersion":
      result("iOS " + UIDevice.current.systemVersion)
    case "processImage":
      guard let args = call.arguments as? [String: Any],
            let imagePath = args["imagePath"] as? String else {
        result(FlutterError(code: "INVALID_ARGUMENTS",
                          message: "Missing or invalid imagePath",
                          details: nil))
        return
      }
      
      processImage(imagePath: imagePath) { processResult in
        result(processResult)
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }
  
  private func processImage(imagePath: String, completion: @escaping ([String: Any]) -> Void) {
    guard let image = UIImage(contentsOfFile: imagePath),
          let cgImage = image.cgImage else {
      completion(["error": "Failed to load image"])
      return
    }
    
    let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])
    let request = VNRecognizeTextRequest { (request, error) in
      if let error = error {
        completion(["error": error.localizedDescription])
        return
      }
      
      guard let observations = request.results as? [VNRecognizedTextObservation] else {
        completion(["error": "No text found"])
        return
      }
      
      // Process the recognized text
      var allText = ""
      var confidence: Float = 0.0
      
      for observation in observations {
        if let topCandidate = observation.topCandidates(1).first {
          allText += topCandidate.string + " "
          confidence += topCandidate.confidence
        }
      }
      
      // Extract numbers from the text
      let numberPattern = try! NSRegularExpression(pattern: "\\d+", options: [])
      let range = NSRange(allText.startIndex..<allText.endIndex, in: allText)
      let matches = numberPattern.matches(in: allText, options: [], range: range)
      
      var numbers = ""
      for match in matches {
        if let range = Range(match.range, in: allText) {
          numbers += allText[range]
        }
      }
      
      // Calculate average confidence
      let avgConfidence = observations.isEmpty ? 0.0 : Float(confidence) / Float(observations.count)
      
      completion([
        "reading": numbers,
        "confidence": avgConfidence,
        "debugInfo": allText
      ])
    }
    
    // Configure the text recognition request
    request.recognitionLevel = .accurate
    request.usesLanguageCorrection = true
    
    do {
      try requestHandler.perform([request])
    } catch {
      completion(["error": error.localizedDescription])
    }
  }
}
