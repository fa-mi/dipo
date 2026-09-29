import SwiftUI
import SwiftData

// Moved out of StatisticsView.swift, unchanged. Also used by ProfileView's backup export.

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
