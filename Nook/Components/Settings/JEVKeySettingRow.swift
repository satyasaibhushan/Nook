// Licensed under GPL-3.0. See LICENSE.
//
//  JEVKeySettingRow.swift
//  Nook
//
//  Sets or clears the JEV key in the Keychain. The saved key is never read back into the UI.
//

import SwiftUI
import NookDesign

struct JEVKeySettingRow: View {
    @State private var hasKey = JEVKeychain.hasKey
    @State private var draft = ""
    @State private var failed = false

    var body: some View {
        LabeledContent {
            HStack(spacing: NookDesign.Spacing.sm) {
                SecureField(hasKey ? "Replace key" : "Key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                    .onSubmit(save)
                Button("Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Clear") {
                    failed = !JEVKeychain.clear()
                    hasKey = JEVKeychain.hasKey
                }
                .disabled(!hasKey)
            }
        } label: {
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                Text("JEV key")
                Text(status)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        if failed { return "Could not update the Keychain." }
        let state = hasKey ? "A key is saved in your Keychain." : "No key saved."
        return "\(state) While a Focus mode is on, JEV labels pages no rule decides, from their address and title only. Private windows are never sent."
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        failed = !JEVKeychain.save(key)
        draft = ""
        hasKey = JEVKeychain.hasKey
    }
}
