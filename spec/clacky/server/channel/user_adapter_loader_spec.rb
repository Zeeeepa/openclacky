# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel"

RSpec.describe Clacky::Channel::Adapters::UserAdapterLoader do
  let(:tmp) { Dir.mktmpdir }

  after { FileUtils.remove_entry(tmp) }

  def write_adapter(name, body)
    dir = File.join(tmp, name)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, "adapter.rb")
    File.write(path, body)
    path
  end

  def valid_adapter_body(platform)
    const = platform.split("_").map(&:capitalize).join
    <<~RUBY
      module Clacky
        module Channel
          module Adapters
            class #{const}Adapter < Base
              def self.platform_id = :#{platform}
              def self.platform_config(data) = {}
              def initialize(config); @config = config; end
              def start(&blk); end
              def stop; end
              def send_text(chat_id, text, reply_to: nil); { message_id: "1" }; end
              Adapters.register(platform_id, self)
            end
          end
        end
      end
    RUBY
  end

  describe ".load_all" do
    it "returns an empty result when the directory is absent" do
      result = described_class.load_all(dir: File.join(tmp, "nope"))
      expect(result.loaded).to be_empty
      expect(result.skipped).to be_empty
    end

    it "loads a valid adapter and registers it" do
      write_adapter("acme", valid_adapter_body("acme_chat"))

      result = described_class.load_all(dir: tmp)

      expect(result.loaded).to eq(["acme"])
      expect(result.skipped).to be_empty
      expect(Clacky::Channel::Adapters.find(:acme_chat)).not_to be_nil
    ensure
      Clacky::Channel::Adapters.unregister(:acme_chat)
    end

    it "skips an adapter missing required interface methods and unregisters it" do
      body = <<~RUBY
        module Clacky
          module Channel
            module Adapters
              class BrokenAdapter < Base
                def self.platform_id = :broken_one
                def self.platform_config(data) = {}
                # missing: start, stop, send_text
                Adapters.register(platform_id, self)
              end
            end
          end
        end
      RUBY
      write_adapter("broken", body)

      result = described_class.load_all(dir: tmp)

      expect(result.loaded).to be_empty
      expect(result.skipped.first[0]).to eq("broken")
      expect(result.skipped.first[1]).to include("send_text")
      expect(Clacky::Channel::Adapters.find(:broken_one)).to be_nil
    end

    it "isolates an adapter with a syntax error" do
      write_adapter("syntax", "class Oops < ; end")

      result = described_class.load_all(dir: tmp)

      expect(result.loaded).to be_empty
      expect(result.skipped.first[0]).to eq("syntax")
    end

    it "skips a file that does not register any adapter" do
      write_adapter("noreg", "module Clacky; module Channel; module Adapters; X = 1; end; end; end")

      result = described_class.load_all(dir: tmp)

      expect(result.loaded).to be_empty
      expect(result.skipped.first[1]).to include("did not register")
    end

    it "caches the result as last_result" do
      write_adapter("cached", valid_adapter_body("cached_one"))
      described_class.load_all(dir: tmp)
      expect(described_class.last_result.loaded).to eq(["cached"])
    ensure
      Clacky::Channel::Adapters.unregister(:cached_one)
    end
  end

  describe ".scaffold" do
    it "generates a self-registering, loadable adapter skeleton" do
      path = described_class.scaffold("my_slack", dir: tmp)

      expect(File.exist?(path)).to be true
      expect(path).to end_with(File.join("my_slack", "adapter.rb"))

      content = File.read(path)
      expect(content).to include("def self.platform_id")
      expect(content).to include(":my_slack")
      expect(content).to include("Adapters.register(platform_id, self)")

      # The skeleton must at least be syntactically valid Ruby.
      expect { RubyVM::InstructionSequence.compile(content) }.not_to raise_error
    end

    it "raises when the adapter already exists" do
      described_class.scaffold("dup", dir: tmp)
      expect { described_class.scaffold("dup", dir: tmp) }.to raise_error(ArgumentError, /already exists/)
    end

    it "raises on an invalid name" do
      expect { described_class.scaffold("!!!", dir: tmp) }.to raise_error(ArgumentError, /invalid channel name/)
    end
  end
end
