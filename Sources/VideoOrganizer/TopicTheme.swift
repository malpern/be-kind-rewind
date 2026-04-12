import SwiftUI

/// Maps topic names to SF Symbol icons and colors.
enum TopicTheme {
    struct Theme {
        let icon: String
        let color: Color
    }

    /// Short display names for sidebar topic labels. Targets ≤22 characters
    /// so labels render single-line in the 280pt sidebar. Keys are the exact
    /// topic names stored in the SQLite topics table.
    private static let displayNameOverrides: [String: String] = [
        // Mechanical Keyboards
        "Keyboard Reviews & Comparisons": "Keyboard Reviews",
        "DIY Builds & Custom Projects": "DIY Keyboard Builds",
        "Keyboard History & Culture": "Keyboard Culture",
        "Ergonomic & Split Keyboards": "Ergo + Split Kbds",
        "Switches & Keycaps": "Switches + Keycaps",
        "Firmware & Software Setup": "Firmware + Setup",
        "Keyboard Layouts & Techniques": "Layouts + Techniques",
        "Soldering & Assembly Techniques": "Soldering + Assembly",

        // AI + ML
        "AI Agents, MCP & Automation Frameworks": "AI Agents + MCP",
        "AI Coding Tools: Cursor, Vibe Coding & IDEs": "AI Coding Tools",
        "AI Coding Tool Comparisons": "AI Tool Comparisons",
        "AI, ML & On-Device Intelligence": "AI + On-Device ML",
        "AI Models, Research & Industry Trends": "AI Models + Research",
        "AI Career & Future of Work": "AI + Future of Work",
        "Software Engineering with AI": "Software + AI",

        // Claude + Anthropic
        "Claude Code & Anthropic Tools": "Claude Code",
        "Claude Models & Anthropic News": "Claude Models",
        "OpenClaw & Clawdbot Deep Dives": "OpenClaw Deep Dives",

        // MCP + Agents
        "Plugins, MCPs & Integrations": "Plugins + MCPs",
        "Agent Design & Architecture": "Agent Architecture",
        "Protocols & Emerging Standards": "Protocols + Standards",
        "MCP Explained & Tutorials": "MCP Explained",

        // Programming + CS
        "Programming Languages, CS Fundamentals & Software Engineering": "CS + Software Eng",
        "Programming Languages, CS Fundamentals & Algorithms": "Programming + CS",
        "Programming Languages & Paradigms": "Languages + Paradigms",
        "Algorithms & Data Structures": "Algorithms + DS",
        "Software Engineering Practices": "Software Engineering",
        "Fullstack Projects & Tutorials": "Fullstack Projects",
        "Frontend Frameworks & Libraries": "Frontend Frameworks",

        // Apple + Swift
        "macOS & Apple Development": "macOS + Apple Dev",
        "macOS Tips & Productivity": "macOS Tips",
        "iOS App Architecture & Patterns": "iOS Architecture",
        "Swift Language & Algorithms": "Swift + Algorithms",
        "SwiftUI Fundamentals & Tutorials": "SwiftUI Fundamentals",
        "Xcode & Developer Tools": "Xcode + Dev Tools",

        // Terminal + Dev Tools
        "Neovim Configuration & Plugins": "Neovim Config",
        "Tmux & Terminal Multiplexers": "Tmux + Multiplexers",
        "Window Management & Customization": "Window Management",
        "Terminal Emulators & Tools": "Terminal Emulators",
        "Developer & Power User Tools": "Dev Tools",
        "Coding & Developer Productivity": "Coding Productivity",

        // Electronics + Embedded
        "Raspberry Pi & Single Board Computers": "Raspberry Pi + SBCs",
        "Microcontrollers & Development Boards": "Microcontrollers",
        "Embedded Programming Languages & RTOS": "Embedded + RTOS",
        "Communication Protocols & Interfaces": "Comm Protocols",
        "Electronics Fundamentals & Theory": "Electronics Theory",
        "Prototyping & Breadboarding": "Prototyping",
        "Components & Test Equipment": "Components + Test",

        // Smart Home
        "Smart Home Hardware Reviews": "Smart Home Hardware",
        "Home Assistant & Platforms": "Home Assistant",
        "Control Systems & Integrations": "Control Systems",
        "Network & Dashboard Setup": "Network + Dashboards",

        // 3D Printing
        "Printer Reviews & Comparisons": "Printer Reviews",
        "Print Finishing & Techniques": "Print Finishing",
        "Design & Modeling Software": "Design Software",

        // Web
        "Web Industry News & Opinions": "Web Industry News",
        "Web Scraping & Automation": "Web Scraping",

        // Retro + History
        "Operating Systems & Software History": "OS History",
        "Reverse Engineering & Advanced Topics": "Reverse Engineering",
        "Vintage Computer Events & Culture": "Vintage Computing",
        "6502 & Retro Programming": "6502 Programming",
        "Retro Hardware & Platforms": "Retro Hardware",
        "Retro Tech & Tech History": "Retro Tech History",
        "Ancient History & Archaeology": "Ancient History",

        // Career + Productivity
        "Career, Indie Dev & Community": "Career + Indie Dev",
        "Career & Professional Growth": "Career Growth",
        "Career, Culture & Industry": "Career + Culture",
        "Productivity, Creativity & Learning": "Productivity",
        "Automation Tools & Workflows": "Automation Tools",
        "Workflows & Productivity Setups": "Workflow Setups",
        "Learning Resources & Books": "Learning + Books",
        "Learning & Skill Development": "Skill Development",
        "Getting Started & Tutorials": "Getting Started",

        // Tech + Gadgets
        "Tech, Gadgets & Digital Tools": "Tech + Digital Tools",
        "Hardware Reviews & Gadgets": "Hardware Reviews",
        "Software, Apps & Browsers": "Software + Browsers",
        "Networking, Data & Storage": "Networking + Storage",
        "Home Office & Desk Setups": "Home Office Setup",
        "Hackintosh & DIY Builds": "Hackintosh + DIY",

        // Content + Media
        "Cameras & Content Creation": "Cameras + Content",
        "Content Creation & Storytelling": "Content Creation",
        "Entertainment, Pop Culture & Media": "Pop Culture + Media",
        "Pop Culture & Media Criticism": "Pop Culture Criticism",

        // Geopolitics
        "Geopolitics, Current Events & Intelligence": "Geopolitics + Intel",
        "Geopolitics & Current Events": "Geopolitics",
        "Global Powers & Geopolitics": "Global Powers",
        "US Politics & Domestic Policy": "US Politics",
        "Intelligence & Covert Operations": "Intel + Covert Ops",

        // Finance
        "Retirement Planning & Lifestyle": "Retirement Planning",
        "Investing & Wealth Building": "Investing",
        "Healthcare & Tax Strategies": "Healthcare + Taxes",
        "Entrepreneurship & Wealth": "Entrepreneurship",

        // Personal
        "Personal Growth & Life Philosophy": "Personal Growth",
        "Health, Lifestyle & Human Interest": "Health + Lifestyle",
        "Simplicity & Lifestyle Design": "Lifestyle Design",
        "Mental Health & Psychology": "Mental Health",
        "Relationships & Social Life": "Relationships",

        // Maker
        "Workshop Organization & Setup": "Workshop Setup",
        "Specialty Projects & Builds": "Specialty Builds",
    ]

    private static let themes: [(keywords: [String], theme: Theme)] = [
        (["keyboard"], Theme(icon: "keyboard", color: .purple)),
        (["claude", "anthropic"], Theme(icon: "brain", color: .orange)),
        (["mcp", "agent", "automation"], Theme(icon: "cpu", color: .blue)),
        (["cursor", "ide", "vibe coding", "coding tool"], Theme(icon: "hammer", color: .indigo)),
        (["ai model", "ai research", "industry trend"], Theme(icon: "sparkles", color: .blue)),
        (["ai"], Theme(icon: "cpu", color: .blue)),
        (["vim", "terminal", "neovim"], Theme(icon: "terminal", color: .green)),
        (["swift", "ios", "swiftui"], Theme(icon: "swift", color: .orange)),
        (["mac", "apple", "wwdc", "xcode"], Theme(icon: "desktopcomputer", color: .gray)),
        (["web", "frontend", "backend", "css", "figma"], Theme(icon: "globe", color: .cyan)),
        (["embedded", "electronic", "pcb", "arduino", "raspberry", "esp32", "microcontroller", "fpga"], Theme(icon: "memorychip", color: .yellow)),
        (["linux", "devops", "docker", "homelab"], Theme(icon: "server.rack", color: .teal)),
        (["retro", "vintage", "classic mac", "apple ii"], Theme(icon: "clock.arrow.trianglehead.counterclockwise.rotate.90", color: .brown)),
        (["3d print", "modeling software"], Theme(icon: "cube", color: .mint)),
        (["home auto", "smart home", "home assistant"], Theme(icon: "house", color: .cyan)),
        (["geopolit", "current event", "politics", "intelligence", "espionage"], Theme(icon: "globe.americas", color: .red)),
        (["finance", "retire", "investing", "fire", "budget"], Theme(icon: "chart.line.uptrend.xyaxis", color: .green)),
        (["health", "lifestyle", "fitness", "nutrition", "longevity", "diet", "exercise"], Theme(icon: "heart", color: .red)),
        (["entertainment", "pop culture", "movie", "tv show", "star trek", "comedy", "film"], Theme(icon: "film", color: .pink)),
        (["productiv", "creative", "learning", "note-taking", "pkm"], Theme(icon: "lightbulb", color: .yellow)),
        (["personal growth", "philosophy", "mindset", "psychology", "career"], Theme(icon: "person.fill", color: .purple)),
        (["programming", "software", "python", "algorithm", "cs fundamental"], Theme(icon: "chevron.left.forwardslash.chevron.right", color: .teal)),
        (["tech", "gadget", "hardware", "networking"], Theme(icon: "wrench.and.screwdriver", color: .gray)),
        (["shell", "cli", "git"], Theme(icon: "apple.terminal", color: .green)),
        (["design", "ui", "ux"], Theme(icon: "paintbrush", color: .pink)),
        (["camera", "photo", "video"], Theme(icon: "camera", color: .secondary)),
        (["music", "art"], Theme(icon: "music.note", color: .pink)),
        (["food", "cooking", "recipe"], Theme(icon: "fork.knife", color: .orange)),
        (["gaming", "game"], Theme(icon: "gamecontroller", color: .indigo)),
        (["robot", "computer vision"], Theme(icon: "gearshape.2", color: .secondary)),
        (["diy", "build", "project", "maker"], Theme(icon: "wrench", color: .orange)),
        (["soldering", "assembly"], Theme(icon: "flame", color: .orange)),
        (["tutorial", "guide", "beginner", "course"], Theme(icon: "book", color: .blue)),
        (["review", "comparison"], Theme(icon: "star", color: .yellow)),
        (["podcast", "interview"], Theme(icon: "mic", color: .purple)),
        (["indie dev", "app business"], Theme(icon: "storefront", color: .green)),
    ]

    private static let defaultTheme = Theme(icon: "folder", color: .secondary)

    static func theme(for topicName: String) -> Theme {
        let lower = topicName.lowercased()
        for entry in themes {
            if entry.keywords.contains(where: { lower.contains($0) }) {
                return entry.theme
            }
        }
        return defaultTheme
    }

    static func iconName(for topicName: String) -> String {
        theme(for: topicName).icon
    }

    static func iconColor(for topicName: String) -> Color {
        theme(for: topicName).color
    }

    static func displayName(for topicName: String) -> String {
        displayNameOverrides[topicName] ?? topicName
    }
}
