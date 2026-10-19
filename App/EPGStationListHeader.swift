import SwiftUI

struct EPGStationListHeader<Actions: View>: View {
    private let title: String
    private let actions: Actions

    init(_ title: String, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 24) {
            Text(title)
                .font(.title2)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: 24)
            HStack(spacing: 16) {
                actions
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 80)
        .padding(.top, 12)
        .padding(.bottom, 24)
    }
}
