import AppKit

/// The About window and the links 5.0.2 shows: homepage, source code, and the
/// contributors it thanks. The standard panel supplies the icon, name, and version.
enum AboutPanel {
    static let homepage = URL(string: "https://switchhosts.vercel.app/home/")!
    static let sourceCode = URL(string: "https://github.com/oldj/SwitchHosts")!
    static let feedback = URL(string: "https://github.com/oldj/SwitchHosts/issues")!

    /// From 5.0.2's `src/common/acknowledgements.ts`, without its one repeated name.
    static let acknowledgements: [(name: String, link: String)] = [
        ("oldj", "https://github.com/oldj"),
        ("Allen.M", "https://github.com/allenm"),
        ("Charles Tang", "https://github.com/charlestang"),
        ("WuJianjun", "https://github.com/stotem"),
        ("Elf Sundae", "https://github.com/ElfSundae"),
        ("zhu yu", "https://github.com/codeyu"),
        ("胖梁", "https://github.com/pangliang"),
        ("CaffreySun", "https://github.com/CaffreySun"),
        ("Xmader", "https://github.com/Xmader"),
        ("Dean Zhang", "https://github.com/zhanggang807"),
        ("CloverNet", "https://github.com/CloverNet"),
        ("ReAlign", "https://github.com/ReAlign"),
        ("Kangyi Cui", "https://github.com/cuikangyi"),
        ("AKIRA", "https://github.com/akrha"),
        ("Constaline", "https://github.com/Constaline"),
        ("TooBug", "https://github.com/TooBug"),
        ("Lussac", "https://github.com/LussacZheng"),
        ("Aktilor", "https://github.com/Aktilor"),
        ("LiangLong", "https://github.com/xxccll"),
        ("ClDaniel1", "https://github.com/ClDaniel1"),
        ("Aaron Xie", "https://github.com/Aaron00101010"),
        ("Stefan Berger", "https://github.com/bergo"),
        ("EmeryWan", "https://github.com/EmeryWan"),
        ("moonheart", "https://github.com/moonheart"),
        ("Wang Weitao", "https://github.com/watonyweng"),
        ("kamatte", "https://github.com/kamatte-me"),
        ("Yuyao Nie", "https://github.com/nieyuyao"),
        ("Xav83", "https://github.com/Xav83"),
        ("Mango Jelly Pudding", "https://github.com/EvanHsieh0415"),
        ("Alex Zappa", "https://github.com/reatlat"),
        ("shenshen", "https://github.com/imshenshen"),
        ("ChunRen Zhang", "https://github.com/rayatn1011"),
        ("Barış Uzun", "https://github.com/barisuzunn"),
        ("Hwang In-wook", "https://github.com/wooklab"),
    ]

    static func show() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits()])
    }

    /// Links first, then the thanks, centred in the panel's small text.
    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 2
        let font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        let plain: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ]
        func link(_ title: String, _ url: String) -> NSAttributedString {
            NSAttributedString(string: title, attributes: plain.merging([.link: url]) { $1 })
        }

        let text = NSMutableAttributedString()
        text.append(link(String(localized: "Homepage"), homepage.absoluteString))
        text.append(NSAttributedString(string: "   ", attributes: plain))
        text.append(link(String(localized: "Source Code"), sourceCode.absoluteString))
        text.append(NSAttributedString(string: "\n\n", attributes: plain))
        var heading = plain
        heading[.font] = NSFont.boldSystemFont(ofSize: NSFont.smallSystemFontSize)
        text.append(NSAttributedString(string: String(localized: "Acknowledgements") + "\n", attributes: heading))
        for (index, person) in acknowledgements.enumerated() {
            if index > 0 { text.append(NSAttributedString(string: "  ", attributes: plain)) }
            text.append(link(person.name, person.link))
        }
        return text
    }
}
