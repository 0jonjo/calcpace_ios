import Foundation

/// A multipart/form-data body: text fields, then one file.
struct RecorderForm {
    let boundary = "calcpace-" + UUID().uuidString
    let body: Data

    var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    init(fields: [(String, String)], file: (name: String, filename: String, type: String, data: Data)) {
        var body = Data()
        func add(_ text: String) { body.append(Data(text.utf8)) }
        for (name, value) in fields {
            add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
        }
        add("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(file.name)\"; filename=\"\(file.filename)\"\r\n")
        add("Content-Type: \(file.type)\r\n\r\n")
        body.append(file.data)
        add("\r\n--\(boundary)--\r\n")
        self.body = body
    }
}
