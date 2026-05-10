# frozen_string_literal: true

require "spec_helper"
require "clacky/server/channel/adapters/feishu/bot"

RSpec.describe Clacky::Channel::Adapters::Feishu::Bot, "document operations" do
  let(:bot) do
    described_class.new(
      app_id: "test_app_id",
      app_secret: "test_app_secret",
      domain: "https://open.feishu.cn"
    )
  end

  before do
    # Stub token acquisition
    allow(bot).to receive(:tenant_access_token).and_return("fake_token")
  end

  describe "#create_document" do
    it "creates a document and returns document_id, title, url" do
      allow(bot).to receive(:post).with(
        "/open-apis/docx/v1/documents",
        { title: "Test Doc" }
      ).and_return({
        "code" => 0,
        "data" => {
          "document" => {
            "document_id" => "doxcn123abc",
            "title" => "Test Doc"
          }
        }
      })

      result = bot.create_document("Test Doc")

      expect(result[:document_id]).to eq("doxcn123abc")
      expect(result[:title]).to eq("Test Doc")
      expect(result[:url]).to eq("https://my.feishu.cn/docx/doxcn123abc")
    end

    it "passes folder_token when provided" do
      allow(bot).to receive(:post).with(
        "/open-apis/docx/v1/documents",
        { title: "Test Doc", folder_token: "fldr_abc" }
      ).and_return({
        "code" => 0,
        "data" => { "document" => { "document_id" => "doxcn456", "title" => "Test Doc" } }
      })

      result = bot.create_document("Test Doc", folder_token: "fldr_abc")
      expect(result[:document_id]).to eq("doxcn456")
    end

    it "raises on API error" do
      allow(bot).to receive(:post).and_return({
        "code" => 99991672,
        "msg" => "scope missing"
      })

      expect { bot.create_document("Fail") }.to raise_error(/Failed to create document/)
    end
  end

  describe "#write_doc_blocks" do
    it "writes blocks to a document" do
      blocks = [
        { "type" => "heading1", "content" => "Hello" },
        { "type" => "text", "content" => "World" }
      ]

      allow(bot).to receive(:post).with(
        "/open-apis/docx/v1/documents/doc123/blocks/doc123/children",
        hash_including(children: an_instance_of(Array), index: 0)
      ).and_return({
        "code" => 0,
        "data" => { "children" => [{ "block_id" => "b1" }, { "block_id" => "b2" }] }
      })

      result = bot.write_doc_blocks("doc123", blocks)
      expect(result[:blocks_created]).to eq(2)
    end

    it "batches blocks when exceeding 50" do
      blocks = Array.new(60) { |i| { "type" => "text", "content" => "line #{i}" } }

      call_count = 0
      allow(bot).to receive(:post) do |_path, body|
        call_count += 1
        children_count = body[:children].length
        { "code" => 0, "data" => { "children" => Array.new(children_count) { {} } } }
      end

      result = bot.write_doc_blocks("doc123", blocks)
      expect(call_count).to eq(2)
      expect(result[:blocks_created]).to eq(60)
    end
  end

  describe "#delete_doc_blocks" do
    it "deletes blocks via a single batch_delete call (Feishu native range semantics)" do
      expect(bot).to receive(:delete).once.with(
        "/open-apis/docx/v1/documents/doc123/blocks/doc123/children/batch_delete",
        { start_index: 1, end_index: 4 }
      ).and_return({ "code" => 0 })

      result = bot.delete_doc_blocks("doc123", 1, 4)
      expect(result[:blocks_deleted]).to eq(3)
    end

    it "supports clearing all content with start_index=0" do
      expect(bot).to receive(:delete).once.with(
        anything,
        { start_index: 0, end_index: 50 }
      ).and_return({ "code" => 0 })

      result = bot.delete_doc_blocks("doc123", 0, 50)
      expect(result[:blocks_deleted]).to eq(50)
    end

    it "raises on negative start_index" do
      expect { bot.delete_doc_blocks("doc123", -1, 3) }.to raise_error(ArgumentError, /start_index must be >= 0/)
    end

    it "raises on invalid range" do
      expect { bot.delete_doc_blocks("doc123", 5, 2) }.to raise_error(ArgumentError, /Invalid range/)
    end

    it "raises on API error" do
      allow(bot).to receive(:delete).and_return({ "code" => 91403, "msg" => "no permission" })

      expect { bot.delete_doc_blocks("doc123", 0, 1) }.to raise_error(/Failed to delete blocks/)
    end
  end

  describe "#list_doc_blocks" do
    it "returns block list with index and preview" do
      allow(bot).to receive(:get).with(
        "/open-apis/docx/v1/documents/doc123/blocks",
        params: { page_size: 500 }
      ).and_return({
        "code" => 0,
        "data" => {
          "items" => [
            { "block_id" => "page_block", "block_type" => 1 },
            { "block_id" => "b1", "block_type" => 3, "heading1" => { "elements" => [{ "text_run" => { "content" => "Title" } }] } },
            { "block_id" => "b2", "block_type" => 2, "text" => { "elements" => [{ "text_run" => { "content" => "Paragraph" } }] } }
          ]
        }
      })

      result = bot.list_doc_blocks("doc123")
      expect(result[:document_id]).to eq("doc123")
      expect(result[:blocks].length).to eq(3)
      expect(result[:blocks][1][:content_preview]).to eq("Title")
      expect(result[:blocks][2][:content_preview]).to eq("Paragraph")
    end
  end

  describe "#build_doc_block (private)" do
    it "maps heading1 type correctly" do
      block = bot.send(:build_doc_block, { "type" => "heading1", "content" => "Hi" })
      expect(block["block_type"]).to eq(3)
      expect(block["heading1"]["elements"][0]["text_run"]["content"]).to eq("Hi")
    end

    it "maps text type correctly" do
      block = bot.send(:build_doc_block, { "type" => "text", "content" => "Para" })
      expect(block["block_type"]).to eq(2)
      expect(block["text"]["elements"][0]["text_run"]["content"]).to eq("Para")
    end

    it "defaults unknown type to text" do
      block = bot.send(:build_doc_block, { "type" => "unknown", "content" => "x" })
      expect(block["block_type"]).to eq(2)
      expect(block["text"]).to be_a(Hash)
    end

    it "handles code blocks with language" do
      block = bot.send(:build_doc_block, { "type" => "code", "content" => "puts 1", "language" => 9 })
      expect(block["block_type"]).to eq(14)
      expect(block["code"]["style"]["language"]).to eq(9)
    end
  end

  describe "#feishu_doc_host (private)" do
    it "returns my.feishu.cn for feishu domain" do
      expect(bot.send(:feishu_doc_host)).to eq("my.feishu.cn")
    end

    it "returns my.larksuite.com for lark domain" do
      lark_bot = described_class.new(
        app_id: "test", app_secret: "test", domain: "https://open.larksuite.com"
      )
      expect(lark_bot.send(:feishu_doc_host)).to eq("my.larksuite.com")
    end
  end
end
