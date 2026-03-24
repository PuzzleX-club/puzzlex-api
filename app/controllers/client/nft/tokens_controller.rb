module Client
  module NFT
    class TokensController < ::Client::ProtectedController
      include Client::IndexerAvailabilityHandling

      def show
        # 这是一个示例，你可能需要根据你的模型和需求来调整
        @token = ItemIndexer::Instance.find(params[:id])
        render json: @token
      end

      # 获取merkle树的根节点
      # 传入itemId
      def root
        item_id = params[:id]
        if item_id.blank?
          render_error("缺少 itemId 参数", :bad_request)
          return
        end

        root = Merkle::TreeNode.get_root(item_id)
        if root.present?
          render_success({ root: root })
        else
          render_error("未找到对应 itemId #{item_id} 的 Merkle Root", :not_found)
        end
      end

      # GET /api/market/tokens/:id/order_basis
      # 返回创建订单所需的标准结构
      def order_basis
        item_id = params[:id]
        if item_id.blank?
          render_error("缺少 item_id 参数", :bad_request)
          return
        end

        instances = ItemIndexer::Instance.where(item: item_id)
        if instances.empty?
          render_error("未找到 item_id #{item_id} 对应的代币实例", :not_found)
          return
        end

        instance_count = instances.count
        token_identifier = instance_count == 1 ? instances.first.id : nil
        criteria_root = nil
        mode = "single"

        if instance_count > 1
          criteria_root = Merkle::TreeNode.get_root(item_id)
          if criteria_root.blank?
            render_error("未找到 item_id #{item_id} 的 Merkle Root", :not_found)
            return
          end
          mode = "collection"
        end

        render_success({
          mode: mode,
          item_id: item_id,
          instance_count: instance_count,
          token_identifier: token_identifier,
          criteria_root: criteria_root,
          collections: [],
          rule: {
            item_ids: [item_id]
          }
        })
      end

      def verify
        token_id = params[:id]
        if token_id.blank?
          render_error("缺少 tokenId 参数", :bad_request)
          return
        end

        is_leaf = Merkle::TreeNode.verify_token(token_id)

        if !is_leaf.nil?
          render_success({ verification: is_leaf })
        else
          render_error("未找到对应 tokenId #{token_id} 的 Merkle 证明", :not_found)
        end
      end

      # 获取merkle树的证明
      # 传入tokenId
      def proof
        token_id = params[:id]
        if token_id.blank?
          render_error("缺少 tokenId 参数", :bad_request)
          return
        end

        proof = Merkle::TreeNode.get_proof(token_id)
        if proof.present?
          render_success({ proof: proof })
        else
          render_error("未找到对应 tokenId #{token_id} 的 Merkle 证明", :not_found)
        end
      end

      # POST /api/nft/tokens/batch_instance_info
      # 批量获取多个Token实例的信息
      def batch_instance_info
        instance_ids = params[:instance_ids]

        if instance_ids.blank? || !instance_ids.is_a?(Array)
          render_error("缺少 instance_ids 参数或格式不正确", :bad_request)
          return
        end

        # 限制批量请求的数量，避免性能问题
        if instance_ids.length > 100
          render_error("一次最多可获取100个实例信息", :bad_request)
          return
        end

        # 从 ItemIndexer::Instance 查找实例（主键是 id）
        instances = ItemIndexer::Instance.where(id: instance_ids)

        # 获取所有相关的 item_ids，批量查询 CatalogData::Item
        item_ids = instances.pluck(:item).uniq
        items_map = CatalogData::Item.where(item_id: item_ids).index_by(&:item_id)

        instances_data = instances.map do |instance|
          item = items_map[instance.item]

          {
            instance_id: instance.id,
            product_id: nil,
            token_name: nil,
            fungible_traits: nil,
            non_fungible_traits: nil,
            gear_score: nil,
            create_time: instance.created_at,
            update_time: instance.updated_at,
            item: item ? {
              itemId: item.item_id,
              item_id: item.item_id,
              product_id: nil,
              name_en: item.name('en'),
              name_cn: item.name('zh'),
              description_item_en: item.description('en'),
              description_item_cn: item.description('zh'),
              icon: item.icon,
              image_url: parse_icon_url(item.icon),
              classification: item.item_type,
              specialization: item.extra('sub_type')
            } : nil
          }
        end

        # 识别找到和未找到的ID
        found_ids = instances.pluck(:id).map(&:to_s)
        missing_ids = instance_ids.map(&:to_s) - found_ids

        render json: {
          code: 0,
          message: "Success",
          data: {
            requested_count: instance_ids.length,
            found_count: instances_data.length,
            missing_count: missing_ids.length,
            instances: instances_data,
            missing_instance_ids: missing_ids
          }
        }
      end

      # GET /api/nft/items/:id/fungible_token
      # 获取指定item_id对应的同质代币token_id
      def get_fungible_token
        item_id = params[:id]  # Rails resources路由中member的参数名是:id
        if item_id.blank?
          render_error("缺少 item_id 参数", :bad_request)
          return
        end

        # 从 CatalogData::Item 获取物品基本信息
        item = CatalogData::Item.find_by(item_id: item_id)
        if item.nil?
          render_error("未找到 item_id #{item_id} 对应的物品信息", :not_found)
          return
        end

        # 从 ItemIndexer::Instance 通过 item 字段查找实例
        instances = ItemIndexer::Instance.where(item: item_id)

        if instances.empty?
          render_error("未找到 item_id #{item_id} 对应的任何代币实例", :not_found)
          return
        end

        # 检查是否只有一个实例（同质代币应该只有一个token_id）
        if instances.count > 1
          render_error("item_id #{item_id} 对应多个代币实例（#{instances.count}个），无法确定唯一的同质代币ID。这可能是一个非同质化代币(NFT)集合。", :unprocessable_entity)
          return
        end

        # 返回唯一的token_id
        instance = instances.first
        render_success({
          item_id: item_id,
          token_id: instance.id,  # ItemIndexer::Instance 主键是 id
          token_name: nil,  # ItemIndexer::Instance 没有 token_name 字段
          item_info: {
            name_cn: item.name('zh'),
            name_en: item.name('en'),
            category: item.item_type
          }
        })
      end

      # GET /api/nft/tokens/:id/instance_info
      # :id 在这里可以是 instance_id 或 criteria
      def instance_info
        id_param = params[:id]
        if id_param.blank?
          render_error("缺少 ID 参数", :bad_request)
          return
        end

        Rails.logger.info "[TokensController] 获取实例信息: #{id_param}"

        # 检查是否为criteria格式（0x开头的hash）
        if id_param.start_with?('0x') && id_param.length == 66
          Rails.logger.info "[TokensController] 检测到criteria格式: #{id_param}"

          # 记录根节点使用情况
          Merkle::TreeRoot.record_usage(id_param)

          # 通过criteria查找item_id
          item_id = Merkle::TreeNode.get_item_id_by_criteria(id_param)

          if item_id.nil?
            render_error("未找到criteria #{id_param} 对应的根节点或item_id无效", :not_found)
            return
          end

          Rails.logger.info "[TokensController] Criteria #{id_param} 对应的 item_id: #{item_id}"

          # 通过item_id获取同质代币的token_id
          begin
            # 从 CatalogData::Item 获取物品基本信息
            item = CatalogData::Item.find_by(item_id: item_id)
            if item.nil?
              render_error("criteria对应的item_id #{item_id} 不存在", :not_found)
              return
            end

            # 从 ItemIndexer::Instance 通过 item 字段查找实例
            instances = ItemIndexer::Instance.where(item: item_id)

            if instances.empty?
              render_error("criteria对应的item_id #{item_id} 无代币实例", :not_found)
              return
            end

            # 检查是否只有一个实例（同质代币应该只有一个token_id）
            if instances.count > 1
              # 多实例情况：返回item基本信息而不是报错
              Rails.logger.info "[TokensController] Criteria #{id_param} 对应多个实例（#{instances.count}个），返回item基本信息"

              item_data = {
                type: "item_info",  # 标识这是基本物品信息而不是具体实例
                item_id: item_id,
                instance_count: instances.count,
                item: {
                  itemId: item.item_id,
                  item_id: item.item_id,
                  product_id: nil,  # CatalogData::Item 没有 product_id
                  name_en: item.name('en'),
                  name_cn: item.name('zh'),
                  description_item_en: item.description('en'),
                  description_item_cn: item.description('zh'),
                  image_url: parse_icon_url(item.icon),
                  category: item.item_type,
                  classification: item.item_type,
                  specialization: item.extra('sub_type')
                }
              }

              render json: { code: 0, message: "Success", data: item_data }
              return
            end

            # 使用找到的唯一实例，立即处理并返回
            instance = instances.first
            Rails.logger.info "[TokensController] ✓ 通过criteria找到唯一实例: #{instance.id}"

            # 构建返回数据 - 使用新的模型结构
            instance_data = {
              instance_id: instance.id,
              product_id: nil,
              token_name: nil,
              fungible_traits: nil,
              non_fungible_traits: nil,
              gear_score: nil,
              create_time: instance.created_at,
              update_time: instance.updated_at,
              item: {
                itemId: item.item_id,
                item_id: item.item_id,
                product_id: nil,
                name_en: item.name('en'),
                name_cn: item.name('zh'),
                description_item_en: item.description('en'),
                description_item_cn: item.description('zh'),
                icon: item.icon,
                image_url: parse_icon_url(item.icon),
                classification: item.item_type,
                specialization: item.extra('sub_type')
              }
            }

            Rails.logger.info "[TokensController] ✓ 成功返回criteria对应的实例信息: #{instance.id}"
            render json: { code: 0, message: "Success", data: instance_data }
            return

          rescue => e
            Rails.logger.error "[TokensController] 处理criteria时出错: #{e.message}"
            Rails.logger.error "[TokensController] 错误堆栈: #{e.backtrace.join("\n")}"
            render_error("处理criteria时发生内部错误: #{e.message}", :internal_server_error)
            return
          end

        else
          # 直接按instance_id查找 (ItemIndexer::Instance 主键是 id)
          Rails.logger.info "[TokensController] 按instance_id查找: #{id_param}"
          instance = ItemIndexer::Instance.find_by(id: id_param)
        end

        if instance
          # 获取对应的 item 信息
          item = CatalogData::Item.find_by(item_id: instance.item)

          # 构建返回数据 - 使用新的模型结构
          instance_data = {
            instance_id: instance.id,
            product_id: nil,
            token_name: nil,
            fungible_traits: nil,
            non_fungible_traits: nil,
            gear_score: nil,
            create_time: instance.created_at,
            update_time: instance.updated_at,
            item: item ? {
              itemId: item.item_id,
              item_id: item.item_id,
              product_id: nil,
              name_en: item.name('en'),
              name_cn: item.name('zh'),
              description_item_en: item.description('en'),
              description_item_cn: item.description('zh'),
              icon: item.icon,
              image_url: parse_icon_url(item.icon),
              classification: item.item_type,
              specialization: item.extra('sub_type')
            } : nil
          }

          Rails.logger.info "[TokensController] ✓ 成功返回实例信息: #{instance.id}"
          render json: { code: 0, message: "Success", data: instance_data }
        else
          render_error("未找到对应 ID #{id_param} 的实例信息", :not_found)
        end
      end

      # 检查根节点状态
      # GET /api/nft/tokens/root_status?root_hash=0x...
      def root_status
        root_hash = params[:root_hash]

        if root_hash.blank?
          render_error("缺少 root_hash 参数", :bad_request)
          return
        end

        status_info = Merkle::TreeRoot.check_root_status(root_hash)

        render_success(status_info)
      end

      # 获取指定item_id的可用根节点列表
      # GET /api/nft/tokens/available_roots?item_id=43
      def available_roots
        item_id = params[:item_id]

        if item_id.blank?
          render_error("缺少 item_id 参数", :bad_request)
          return
        end

        limit = params[:limit]&.to_i || 20
        roots = Merkle::TreeRoot.all_roots_for_item(item_id, limit)

        render_success({
          item_id: item_id,
          roots: roots,
          total_count: roots.length
        })
      end

      # 获取Merkle树系统统计信息
      # GET /api/nft/tokens/merkle_stats
      def merkle_stats
        stats = Merkle::TreeRoot.statistics

        render_success(stats)
      end

      # GET /api/nft/tokens/:id/latest_root
      # 获取指定 item_id 最新的、可用的 Merkle Tree 根节点信息
      def latest_root
        item_id = params[:id] # 路由参数是 :id
        latest_root_record = Merkle::TreeRoot.latest_active_root(item_id)

        if latest_root_record
          render_success({
            root_hash: latest_root_record.root_hash,
            created_at: latest_root_record.created_at,
            expires_at: latest_root_record.expires_at,
            token_count: latest_root_record.token_count
          })
        else
          render_error("No active Merkle tree root found for item_id #{item_id}", :not_found)
        end
      end

      # GET /api/nft/tokens/:criteria_hash/validate_token
      # 验证某个 token_id 是否在指定的 Merkle Tree (由 criteria_hash 代表) 中
      def validate_token_in_tree
        criteria_hash = params[:criteria_hash]
        token_id_to_check = params[:token_id]

        # 验证 token_id 是否存在
        unless token_id_to_check.present?
          render json: { success: false, is_valid: false, message: 'token_id is required' }, status: :bad_request
          return
        end

        # 查找根节点是否存在（使用最新的活跃根节点）
        root_record = Merkle::TreeRoot.find_latest_active_by_root_hash(criteria_hash)
        unless root_record
          render json: { success: false, is_valid: false, message: 'Merkle root not found or has expired' }, status: :not_found
          return
        end

        # 在对应的 Merkle Tree 中查找叶子节点
        is_valid = Merkle::TreeNode.exists?(snapshot_id: root_record.snapshot_id, token_id: token_id_to_check, is_leaf: true)

        if is_valid
          render json: { success: true, is_valid: true, message: 'Token ID is valid for this collection order.' }
        else
          render json: { success: true, is_valid: false, message: 'Token ID is not part of this collection order.' }
        end
      end

      # GET /api/nft/tokens/root_info/:root_hash
      # 根据特定的Merkle root hash获取对应的Merkle树信息
      # 这个API用于获取订单创建时使用的特定Merkle树信息，而不是最新的
      def root_info
        root_hash = params[:root_hash]

        if root_hash.blank?
          render_error("缺少 root_hash 参数", :bad_request)
          return
        end

        # 查找特定root_hash对应的根节点记录
        root_record = Merkle::TreeRoot.find_by_root_hash(root_hash)

        if root_record
          render_success({
            root_hash: root_record.root_hash,
            created_at: root_record.created_at,
            expires_at: root_record.expires_at,
            token_count: root_record.token_count,
            item_id: root_record.item_id,
            tree_exists: root_record.tree_exists
          })
        else
          render_error("未找到指定的Merkle root: #{root_hash}", :not_found)
        end
      end

      private

      def token_params
        params.require(:token).permit(:tokenId)
      end

      # 解析icon字段的JSON数组，返回第一个URL
      def parse_icon_url(icon_field)
        return nil if icon_field.blank?

        begin
          # icon字段存储的是JSON数组字符串，例如：'["https://example.com/image.png"]'
          parsed = JSON.parse(icon_field)
          if parsed.is_a?(Array) && parsed.any?
            return parsed.first
          end
        rescue JSON::ParserError => e
          Rails.logger.warn "[TokensController] Failed to parse icon JSON: #{icon_field}, error: #{e.message}"
        end

        # 如果解析失败，尝试直接返回（可能已经是URL字符串）
        icon_field
      end
    end
  end
end
