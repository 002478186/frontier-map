import SwiftUI

/// Shown once, on a first launch: what the app does and a guide to ride with. Location is asked for only when you
/// leave it, so the permission prompt comes after the reason for it.
struct Welcome: View {
    @ObservedObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Frontier Map").font(.frontier(44))
                    Text("Every road's a trail. Every trip's a story.").font(.callout.italic())
                }
                .padding(.top, 40)

                VStack(alignment: .leading, spacing: 14) {
                    point("map.fill", "A hand-inked map of wherever you are", "Switch to Modern or Topo any time from the layers button.")
                    point("arrow.triangle.turn.up.right.diamond.fill", "Turn-by-turn, spoken in character",
                          "Car, walk or bike. The voices run on the phone, with no signal needed.")
                    point("eye.slash.fill", "The fog lifts where you go", "Parks, peaks and landmarks you pass get marked in your journal.")
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("Pick your guide").font(.frontier(22))
                    Text("Tap one to hear them. You can change your mind in the Journal.").font(.caption)
                    ForEach(Rider.allCases) { r in
                        Button {
                            model.rider = r
                            model.say(r.toward("Camp", "3 miles northeast"))
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name).font(.frontier(18))
                                    Text(r.blurb).font(.caption).multilineTextAlignment(.leading)
                                }
                                Spacer()
                                Image(systemName: model.rider == r ? "checkmark.circle.fill" : "circle")
                            }
                            .padding(10)
                            .background(Color.ink.opacity(model.rider == r ? 0.14 : 0.05), in: RoundedRectangle(cornerRadius: 10))
                        }
                        .accessibilityAddTraits(model.rider == r ? .isSelected : [])
                    }
                }

                VStack(spacing: 8) {
                    Button { model.welcomed = true } label: {
                        Text("Saddle up").font(.frontier(22)).frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .foregroundStyle(Color.parchment)
                    .background(Color.ink, in: RoundedRectangle(cornerRadius: 12))
                    Text("Next, iOS asks to use your location. It stays on this phone.")
                        .font(.caption).frame(maxWidth: .infinity)
                }
                .padding(.bottom, 24)
            }
            .padding(.horizontal, 24)
        }
        .foregroundStyle(Color.ink)
        .background(Color.parchment.ignoresSafeArea())
    }

    private func point(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title3).frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline)
            }
        }
    }
}
