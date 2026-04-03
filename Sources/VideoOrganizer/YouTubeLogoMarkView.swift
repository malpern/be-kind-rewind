import SwiftUI

struct YouTubeLogoMarkView: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color(red: 1, green: 0, blue: 0))

            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: 1)
        }
        .frame(width: 30, height: 22)
        .accessibilityHidden(true)
    }
}
