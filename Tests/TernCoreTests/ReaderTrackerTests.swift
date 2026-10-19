import Foundation
import Testing
@testable import TernCore

private func loaded(_ html: String) -> SanitizedMail {
    MailSanitizer.sanitize(html: html, options: .init(allowRemoteImages: true, remoteImageURL: { "tern-remote://i/sig/" + $0 }))
}

@Test(arguments: [
    "https://track.customer.io/e/o/eyJlbWFpbF9pZCI6IkRlc0FBQUdC",
    "https://notifylink.example.app/e/o/ZXhhbXBsZS10b2tlbi0xMjM0NTY3ODkw",
    "https://links.iterable.com/e/o?_t=abc&_m=def",
    "https://u1234567.ct.sendgrid.net/wf/open?upn=abc",
    "https://url5512.acme.com/wf/open?upn=xyz",
    "http://email.mg.acme.com/o/eJwtzEEOgjAQBdC7zLobl1yGTOkHmrSdZqYGjeHuGnX9kneniCGd4rk2kGdNSiN0yCw5KjmyA0cR5CQoBTqm0b2gg1zZ9q4gKt3nUafSJ2w0P5yoMTwZ1jMfgV1V9SOm0WFsZ9sIpsjRnJAHKXrkIhemijgdwy1zj56Fq3XQ5XVyqQ3VqZgLw2vlXmY3rc5fZ+5U0GyJ/fwrlcPP8f4ld/O3pW/zecPWLchK",
    "https://email.acme.com/o/AAAAAKMs8sQ7c8nPZr5L8wQ2Yb2kDh",
    "https://xyz.r.us-east-1.awstrack.me/I0/0100018aa6e7f0b4-1/abc=345",
    "https://ea.pstmrk.it/open?m=v3_1.abc",
    "https://pmtrk.example.com/x",
    "https://t.hubspotemail.net/e2t/to/VVWB",
    "https://track.hubspot.com/__ptq.gif?a=1",
    "https://acme.us4.list-manage.com/track/open.php?u=1&id=2",
    "https://news.example.com/track/open?id=9",
    "https://cdn.example.com/mail/open.gif?id=7",
    "https://example.com/campaign/open.php?u=1",
    "https://example.com/images/pixel.gif",
    "https://example.com/1x1.gif",
    "https://stats.example.com/beacon/12345",
    "https://example.com/v1/beacon?m=1",
    "https://example.com/%62eacon/x",
    "https://example.com\\wf\\open?x",
    "https://acme.createsend1.com/t/y-o-abcdef-l/o.gif",
    "https://cl.s7.exct.net/open.aspx?ffcb10-fe8f1374-12",
    "https://eotrx.substackcdn.com/open?token=eyJtIjoiMSJ9&e=1",
    "https://abc.r.bh.d.sendibt3.com/tr/op/AbCdEf123-xyz",
    "https://links.acme.com/tr/op/AbCdEf123",
    "https://x8k2.mjt.lu/oo/BAAAAD4abc/aBc12/b.gif",
    "https://www.google-analytics.com/collect?v=1&tid=UA-1&t=event",
    "https://ssl.google-analytics.com/__utm.gif?utmac=1",
])
func openTrackersNeverLoad(_ url: String) {
    #expect(MailTrackers.isTracker(url), "\(url)")
    let mail = loaded("<img src=\"\(url)\" width=\"250\" height=\"60\" alt=\"x\"><div style=\"background:url(\(url))\">x</div>")
    #expect(!mail.html.contains("tern-remote"), "dropped before any request: \(mail.html)")
    #expect(!mail.html.contains("<img"), "and without a stand-in box: \(mail.html)")
}

@Test(arguments: [
    "https://res.cloudinary.com/acme/image/upload/v1/emails/logo.png",
    "https://images.example.com/open/hero.png",
    "https://cdn.example.com/e/logo.png",
    "https://cdn.example.com/e/o.png",
    "https://email.acme.com/images/logo.png",
    "https://email.acme.com/o/logo.png",
    "https://xyz.r.us-east-1.awstrack.me/L0/https:%2F%2Facme.com%2Flogo.png/1/abc",
    "https://cdn.example.com/beacon-logo.png",
    "https://cdn.example.com/track/opening-hours.png",
    "https://cdn.shopify.com/s/files/1/0001/open-house.jpg",
    "https://i.pstmrk.it/images/logo.png",
    "https://substackcdn.com/image/fetch/w_1456,c_limit,f_webp,q_auto:good/https%3A%2F%2Fsubstack-post-media.s3.amazonaws.com%2Fpublic%2Fimages%2Fabc.png",
    "https://substack-post-media.s3.amazonaws.com/public/images/open.jpeg",
    "https://image.s7.exct.net/lib/fe8f1374/m/1/logo.png",
    "https://i1.createsend1.com/ei/r/12/345/csimport/logo.png",
    "https://img.mailinblue.com/2607945/images/content_library/original/logo.png",
    "https://cdn.example.com/tr/op.png",
    "https://x8k2.mjt.lu/img/logo.png",
    "https://www.google.com/images/branding/googlelogo/2x/googlelogo_color_92x30dp.png",
])
func ordinaryImagesStillLoad(_ url: String) {
    #expect(!MailTrackers.isTracker(url), "\(url)")
    let mail = loaded("<img src=\"\(url)\" width=\"250\" alt=\"Logo\">")
    #expect(mail.html.contains("src=\"tern-remote://i/sig/\(url.replacingOccurrences(of: "&", with: "&amp;"))\""), "\(mail.html)")
}

@Test func hiddenAndTinyImagesArePixels() {
    let pixels = [
        #"width="1" height="1""#, #"width="1""#, #"height="1px""#, #"width=" 0 ""#, #"width="2" height="2""#,
        #"width="1" height="2""#, #"width="600" height="0""#, #"style="height:1px""#, #"style="width: 0""#,
        #"style="max-height:0""#, #"width="600" style="max-height:0""#, #"style="max-width: 0px !important""#,
        #"style="display: none""#, #"style="DISPLAY:NONE""#, #"style="visibility:hidden""#, #"style="opacity:0""#,
        #"style="opacity: 0.0""#, #"style="opacity:0%""#, #"style="height:0.75pt""#, #"hidden"#,
        #"width="600" style="height:1px;width:1px;max-height:1px;max-width:1px;display:block""#,
        #"width="600" height="2" style="width:2px""#, #"width="0%""#, #"style="height:1px;max-width:100%""#,
    ]
    for attributes in pixels {
        let mail = loaded("<p>a</p><img src=\"https://cdn.example/x.png\" \(attributes) alt=\"\">")
        #expect(!mail.html.contains("<img"), "\(attributes) → \(mail.html)")
        let protocolRelative = loaded("<img src=\"//cdn.example/x.png\" \(attributes)>")
        #expect(!protocolRelative.html.contains("<img"), "protocol-relative \(attributes) → \(protocolRelative.html)")
    }
    // Dividers and spacers draw something: one thin side is fine while the other is known and bigger.
    let images = [
        #"width="250""#, #"width="600" height="300""#, #"width="100%""#, #"style="width:250px;max-width:100%""#,
        #"style="opacity:0.9""#, #"style="height:auto""#, #"style="max-height:3px""#, #"width="3" height="3""#,
        #"width="600" height="2""#, #"width="600" height="1""#, #"width="1" height="20""#, #"width="2" height="40""#,
        #"style="width:600px;height:1px""#, #"width="100%" height="1""#, #"height="2""#, #"width="2""#,
        #"width="1" style="width:600px""#, #"style="width:100%;height:1px""#,
    ]
    for attributes in images {
        let mail = loaded("<img src=\"https://cdn.example/x.png\" \(attributes)>")
        #expect(mail.html.contains("tern-remote://i/sig/https://cdn.example/x.png"), "\(attributes) → \(mail.html)")
    }
    // Pixels are a remote concern: a tiny inline or data: image stays.
    #expect(loaded("<img src=\"data:image/png;base64,iVBORw0KGgo=\" width=\"1\" height=\"1\">").html.contains("<img"))
    #expect(MailSanitizer.sanitize(html: "<img src=\"cid:dot\" width=\"1\">", options: .init { "tern-cid://m/a/m/\($0)" })
        .html.contains("tern-cid://m/a/m/dot"))
}
