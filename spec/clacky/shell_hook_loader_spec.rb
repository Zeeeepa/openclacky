# frozen_string_literal: true

require "spec_helper"

RSpec.describe Clacky::ShellHookLoader do
  let(:tmp) { Dir.mktmpdir }
  let(:yml) { File.join(tmp, "hooks.yml") }

  after { FileUtils.remove_entry(tmp) }

  def write_yml(content)
    File.write(yml, content)
  end

  describe ".load_into" do
    it "returns empty when the file is absent" do
      result = described_class.load_into(Clacky::HookManager.new, path: File.join(tmp, "none.yml"))
      expect(result.registered).to be_empty
      expect(result.skipped).to be_empty
    end

    it "registers a hook for a valid event" do
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - name: guard
              command: "true"
      YAML
      hm = Clacky::HookManager.new
      result = described_class.load_into(hm, path: yml)

      expect(result.registered).to eq([[:before_tool_use, "guard"]])
      expect(hm.has_hooks?(:before_tool_use)).to be true
    end

    it "skips an unknown event" do
      write_yml(<<~YAML)
        hooks:
          not_a_real_event:
            - command: "true"
      YAML
      result = described_class.load_into(Clacky::HookManager.new, path: yml)
      expect(result.skipped.first[1]).to include("unknown event")
    end

    it "skips a spec with no command" do
      write_yml(<<~YAML)
        hooks:
          on_start:
            - name: nope
      YAML
      result = described_class.load_into(Clacky::HookManager.new, path: yml)
      expect(result.skipped.first[1]).to include("missing command")
    end
  end

  describe "runtime contract" do
    it "denies a tool when the command exits 2, using STDOUT as the reason" do
      script = File.join(tmp, "deny.sh")
      File.write(script, "#!/usr/bin/env bash\necho \"nope\"\nexit 2\n")
      FileUtils.chmod("+x", script)
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
      YAML
      hm = Clacky::HookManager.new
      described_class.load_into(hm, path: yml)

      result = hm.trigger(:before_tool_use, { name: "terminal" })
      expect(result[:action]).to eq(:deny)
      expect(result[:reason]).to eq("nope")
    end

    it "allows when the command exits 0" do
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "true"
      YAML
      hm = Clacky::HookManager.new
      described_class.load_into(hm, path: yml)

      result = hm.trigger(:before_tool_use, { name: "terminal" })
      expect(result[:action]).to eq(:allow)
    end

    it "passes the event payload as JSON on STDIN" do
      out = File.join(tmp, "captured.json")
      script = File.join(tmp, "capture.sh")
      File.write(script, "#!/usr/bin/env bash\ncat > \"#{out}\"\nexit 0\n")
      FileUtils.chmod("+x", script)
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
      YAML
      hm = Clacky::HookManager.new
      described_class.load_into(hm, path: yml)
      hm.trigger(:before_tool_use, { name: "terminal", arguments: { cmd: "ls" } })

      payload = JSON.parse(File.read(out))
      expect(payload["event"]).to eq("before_tool_use")
      expect(payload["tool"]["name"]).to eq("terminal")
    end

    it "allows (does not raise) when the command times out" do
      script = File.join(tmp, "slow.sh")
      File.write(script, "#!/usr/bin/env bash\nsleep 5\nexit 2\n")
      FileUtils.chmod("+x", script)
      write_yml(<<~YAML)
        hooks:
          before_tool_use:
            - command: "#{script}"
              timeout: 1
      YAML
      hm = Clacky::HookManager.new
      described_class.load_into(hm, path: yml)

      result = hm.trigger(:before_tool_use, { name: "terminal" })
      expect(result[:action]).to eq(:allow)
    end
  end

  describe ".scaffold" do
    it "creates hooks.yml and an executable example script" do
      path = described_class.scaffold(path: yml)
      expect(File.exist?(path)).to be true
      expect(File.read(path)).to include("before_tool_use")

      script = File.join(tmp, "hook-scripts", "deny-example.sh")
      expect(File.exist?(script)).to be true
      expect(File.executable?(script)).to be true
    end

    it "raises if hooks.yml already exists" do
      described_class.scaffold(path: yml)
      expect { described_class.scaffold(path: yml) }.to raise_error(ArgumentError, /already exists/)
    end
  end
end
