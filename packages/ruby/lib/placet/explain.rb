# frozen_string_literal: true

module Placet
  # 実効権限と決定根拠の説明表示（rails placet:explain 等が利用する）。
  # Rails には依存しない。resolver はアプリの user オブジェクトを必要とするため、
  # explain は principal 集合を直接受け取り、derive の 1 段展開だけを適用する
  module Explain
    module_function

    # principal に直接・derive 経由でアタッチされる policy を一覧する
    def principal_report(principal)
      lines = [principal]
      Placet.expand_principals([principal]).each do |expanded, via|
        if expanded == principal
          append_policies(lines, expanded, indent: "  ")
        else
          lines << "  └─ #{expanded}（#{via.join(' ← ')} から導出）"
          append_policies(lines, expanded, indent: "       ")
        end
      end
      lines.join("\n")
    end

    # principal 集合（derive 展開込み）で action を判定し、根拠を表示する
    def decision_report(principals, action)
      decision = Placet.decide_with_provenance(Placet.expand_principals(principals), action)
      lines = ["#{decision.decision} (#{decision.basis})"]
      decision.determinants.each do |d|
        line = "└─ #{d.effect}: policy \"#{d.policy}\" statement #{d.statement} via #{d.principal}"
        line += " ← #{d.via.join(' ← ')}" if d.via
        lines << line
      end
      lines << "└─ マッチする statement なし（implicit deny）" if decision.determinants.empty?
      lines.join("\n")
    end

    def append_policies(lines, principal, indent:)
      names = Placet.definition.attachments.fetch(principal, [])
      return lines << "#{indent}（アタッチされた policy なし）" if names.empty?

      names.each do |name|
        lines << "#{indent}policy: #{name}"
        Placet.definition.policies[name].each do |st|
          lines << "#{indent}  #{st.effect} #{st.actions.join(', ')}"
        end
      end
    end
  end
end
