import Foundation

assert(SharePayload.body(from: [" https://example.com/place ", "https://example.com/place"]) == "https://example.com/place")
assert(SharePayload.body(from: ["Try this https://example.com/place tonight", "https://example.com/place"]) == "Try this https://example.com/place tonight")
assert(SharePayload.body(from: ["https://example.com", "https://example.com/place"]) == "https://example.com\n\nhttps://example.com/place")
assert(SharePayload.body(from: ["", " \n ", "Dinner plans"]) == "Dinner plans")
print("Share payload checks passed")
