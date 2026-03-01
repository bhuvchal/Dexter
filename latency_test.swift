import Foundation

// Just checking if we can get a quick latency measurement on string processing
let start = DispatchTime.now()
var processed = ""
let str = String(repeating: " ", count: 1000)
for c in str {
    processed.append(c)
}
let end = DispatchTime.now()
let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
let timeInterval = Double(nanoTime) / 1_000_000_000
print("Time to process 1000 spaces: \(timeInterval) seconds")
