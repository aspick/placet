# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "placet"
require "placet/test_helpers"

CONFORMANCE_DIR = File.expand_path("../../../spec/conformance", __dir__)

# 適合性 fixture のロードとテストメソッド定義の共通足場。
# 各テストクラスは extend して、検証本体のブロックだけを渡す
module ConformanceLoader
  def define_conformance_tests(subdir, &assertion)
    Dir[File.join(CONFORMANCE_DIR, subdir, "*.json")].sort.each do |path|
      fixture = JSON.parse(File.read(path))
      engine = Placet::Engine.new(Placet::Definition.from_canonical(fixture["document"]))

      fixture["cases"].each do |kase|
        define_method("test_#{fixture['name']}__#{kase['name'].gsub(/\W+/, '_')}") do
          instance_exec(engine, kase, &assertion)
        end
      end
    end
  end
end
