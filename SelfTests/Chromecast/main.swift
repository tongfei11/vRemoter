import Foundation
assert(ChromecastButtonReport.decode(reportID: 2, data: Data([2, 0x41, 0])) == "07")
assert(ChromecastButtonReport.decode(reportID: 2, data: Data([0x41, 0])) == "07")
assert(ChromecastButtonReport.decode(reportID: 1, data: Data([1, 0, 0, 0x28, 0, 0, 0, 0, 0])) == "07")
assert(ChromecastButtonReport.decode(reportID: 1, data: Data([1,0,0,0x52,0,0,0,0,0])) == "03")
assert(ChromecastButtonReport.decode(reportID: 2, data: Data([2,0,0])) == "00")
assert(ChromecastButtonReport.decode(reportID: 2, data: Data([2,0x99,0x99])) == nil)
assert(ChromecastButtonReport.decode(reportID: 1, data: Data([1,7])) == "07")
print("Chromecast report tests passed")
