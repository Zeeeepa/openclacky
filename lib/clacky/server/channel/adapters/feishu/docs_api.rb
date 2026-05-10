# frozen_string_literal: true

module Clacky
  module Channel
    module Adapters
      module Feishu
        # Feishu Docx (cloud document) read/write operations.
        #
        # This module is included into Bot to keep bot.rb focused on
        # messaging concerns. It depends on the host class providing:
        #   - get(path, params:)
        #   - post(path, body)
        #   - delete(path, body)
        #   - @domain instance variable (for building user-facing doc URLs)
        #
        # Public API:
        #   - create_document(title, folder_token:)
        #   - write_doc_blocks(document_id, blocks, index:)
        #   - delete_doc_blocks(document_id, start_index, end_index)
        #     (Feishu native semantics: deletes children (start_index, end_index])
        #   - list_doc_blocks(document_id)
        module DocsApi
          # Create a new Feishu document.
          # @param title [String] Document title
          # @param folder_token [String, nil] Folder to create in (nil = root)
          # @return [Hash] { document_id:, title:, url: }
          def create_document(title, folder_token: nil)
            body = { title: title }
            body[:folder_token] = folder_token if folder_token && !folder_token.empty?

            response = post("/open-apis/docx/v1/documents", body)
            code = response["code"].to_i
            raise "Failed to create document: code=#{code} msg=#{response["msg"]}" unless code == 0

            doc_id = response.dig("data", "document", "document_id")
            {
              document_id: doc_id,
              title: response.dig("data", "document", "title"),
              url: "https://#{feishu_doc_host}/docx/#{doc_id}"
            }
          end

          # Write content blocks to a Feishu document.
          # Accepts a simplified block format and converts to Feishu API format.
          #
          # @param document_id [String] Document ID
          # @param blocks [Array<Hash>] Simplified blocks, e.g.:
          #   [{"type" => "heading1", "content" => "Title"},
          #    {"type" => "text", "content" => "Paragraph"}]
          # @param index [Integer] Insert position (0 = beginning, after the page block)
          # @return [Hash] { blocks_created: Integer }
          def write_doc_blocks(document_id, blocks, index: 0)
            api_blocks = blocks.map { |b| build_doc_block(b) }
            total_created = 0

            # Feishu API limits batch to 50 blocks
            api_blocks.each_slice(50).with_index do |batch, batch_idx|
              response = post(
                "/open-apis/docx/v1/documents/#{document_id}/blocks/#{document_id}/children",
                { children: batch, index: index + (batch_idx * 50) }
              )
              code = response["code"].to_i
              raise "Failed to write blocks (batch #{batch_idx + 1}): code=#{code} msg=#{response["msg"]}" unless code == 0

              total_created += response.dig("data", "children")&.length || batch.length
            end

            { blocks_created: total_created }
          end

          # Delete a contiguous range of blocks from a Feishu document.
          #
          # Uses Feishu's native batch_delete which performs an atomic range
          # delete in a single API call. The semantics follow Feishu's API:
          # the deleted range is the children at positions
          # (start_index, end_index] — i.e. start_index is exclusive and
          # end_index is inclusive. start_index = 0 means "delete starting
          # right after the root block", which is the typical full-clear case.
          #
          # Examples:
          #   - Clear all content: delete_doc_blocks(id, 0, last_index)
          #   - Delete a single block at index K: delete_doc_blocks(id, K-1, K)
          #   - Delete blocks [a..b] (inclusive): delete_doc_blocks(id, a-1, b)
          #
          # @param document_id [String] Document ID
          # @param start_index [Integer] Exclusive start (must be >= 0)
          # @param end_index [Integer] Inclusive end (must be > start_index)
          # @return [Hash] { blocks_deleted: Integer }
          def delete_doc_blocks(document_id, start_index, end_index)
            raise ArgumentError, "start_index must be >= 0, got #{start_index}" if start_index < 0
            raise ArgumentError, "Invalid range: start=#{start_index} end=#{end_index}" if end_index <= start_index

            response = delete(
              "/open-apis/docx/v1/documents/#{document_id}/blocks/#{document_id}/children/batch_delete",
              { start_index: start_index, end_index: end_index }
            )
            code = response["code"].to_i
            raise "Failed to delete blocks (start=#{start_index} end=#{end_index}): code=#{code} msg=#{response["msg"]}" unless code == 0

            { blocks_deleted: end_index - start_index }
          end

          # Get document block list (for inspecting structure).
          # @param document_id [String] Document ID
          # @return [Hash] { blocks: Array }
          def list_doc_blocks(document_id)
            response = get("/open-apis/docx/v1/documents/#{document_id}/blocks", params: { page_size: 500 })
            code = response["code"].to_i
            raise "Failed to list blocks: code=#{code} msg=#{response["msg"]}" unless code == 0

            items = response.dig("data", "items") || []
            {
              document_id: document_id,
              blocks: items.map.with_index { |block, idx|
                {
                  index: idx,
                  block_id: block["block_id"],
                  block_type: block["block_type"],
                  content_preview: extract_block_text(block)
                }
              }
            }
          end

          # Convert simplified block format to Feishu API block structure.
          # Supported types: text, heading1-9, code, bullet, ordered
          # @param block [Hash] { "type" => "heading1", "content" => "..." }
          # @return [Hash] Feishu API block
          private def build_doc_block(block)
            type = block["type"] || "text"
            content = block["content"] || ""

            block_type, key = case type
                              when "heading1" then [3, "heading1"]
                              when "heading2" then [4, "heading2"]
                              when "heading3" then [5, "heading3"]
                              when "heading4" then [6, "heading4"]
                              when "heading5" then [7, "heading5"]
                              when "heading6" then [8, "heading6"]
                              when "heading7" then [9, "heading7"]
                              when "heading8" then [10, "heading8"]
                              when "heading9" then [11, "heading9"]
                              when "bullet"   then [12, "bullet"]
                              when "ordered"  then [13, "ordered"]
                              when "code"     then [14, "code"]
                              else                 [2, "text"] # default: paragraph
                              end

            result = {
              "block_type" => block_type,
              key => {
                "elements" => [{ "text_run" => { "content" => content } }],
                "style" => {}
              }
            }

            # Code blocks need language specification
            if type == "code"
              result[key]["style"] = { "language" => (block["language"] || 1) }
            end

            result
          end

          # Extract text preview from a Feishu block (for list_doc_blocks).
          # @param block [Hash] raw block from API
          # @return [String]
          private def extract_block_text(block)
            # Try common content keys
            %w[text heading1 heading2 heading3 heading4 heading5 heading6
               heading7 heading8 heading9 bullet ordered code].each do |key|
              elements = block.dig(key, "elements")
              next unless elements

              return elements.filter_map { |e|
                e.dig("text_run", "content")
              }.join.slice(0, 100)
            end
            ""
          end

          # Return the Feishu document host based on configured domain.
          # @return [String] e.g. "my.feishu.cn" or "my.larksuite.com"
          private def feishu_doc_host
            Feishu.doc_host_for(@domain)
          end
        end
      end
    end
  end
end
