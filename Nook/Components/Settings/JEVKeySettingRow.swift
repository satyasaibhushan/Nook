// Licensed under GPL-3.0. See LICENSE.
//
//  JEVKeySettingRow.swift
//  Nook
//
//  Sets or clears the AI judge key in the Keychain. The saved key is never read back into the UI.
//

import SwiftUI
import NookDesign
import NookWeb

struct JEVKeySettingRow: View {
    let provider: ActivityJudgeProvider
    @State private var hasKey: Bool
    @State private var draft = ""
    @State private var failed = false

    init(provider: ActivityJudgeProvider) {
        self.provider = provider
        _hasKey = State(initialValue: JudgeKeychain.hasKey(provider))
    }

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
                    failed = !JudgeKeychain.clear(provider)
                    hasKey = JudgeKeychain.hasKey(provider)
                }
                .disabled(!hasKey)
            }
        } label: {
            VStack(alignment: .leading, spacing: NookDesign.Spacing.xxs) {
                Text("\(judgeProviderName(provider)) key")
                Text(status)
                    .font(NookDesign.Font.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var status: String {
        if failed { return "Could not update the Keychain." }
        let state = hasKey ? "A key is saved in your Keychain." : "No key saved."
        return "\(state) Used for pages and posts no rule decides: page address and title, or post text and author. Private windows are never sent."
    }

    private func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        failed = !JudgeKeychain.save(key, for: provider)
        draft = ""
        hasKey = JudgeKeychain.hasKey(provider)
    }
}

func judgeProviderName(_ provider: ActivityJudgeProvider) -> String {
    switch provider {
    case .openAIDecisions: return "OpenAI Decisions"
    case .typeSafeJev: return "TypeSafe Jev"
    }
}
