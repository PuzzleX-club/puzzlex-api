Rails.application.routes.draw do
  get '/health', to: 'system/health#show'
  get '/health/sidekiq', to: 'system/health#sidekiq'
  get '/health/admin-debug', to: 'system/health#admin_debug'

  mount ActionCable.server => '/cable'

  # Admin API (feature flag 控制) - controllers under Admin namespace
  if Rails.application.config.admin_features_enabled
    scope path: '/api/admin' do
      get '/items', to: 'admin/items#index'
      get '/markets', to: 'admin/markets#index'
      post '/markets', to: 'admin/markets#create'
      delete '/markets/:id', to: 'admin/markets#destroy'
      get '/users', to: 'admin/users#index'
      post '/users/:id/grant_admin', to: 'admin/users#grant_admin'
      post '/users/:id/revoke_admin', to: 'admin/users#revoke_admin'
      get '/stats', to: 'admin/stats#index'
      get '/orders/full_list', to: 'client/market/trading/orders#full_list'
    end
  end

  namespace :api do
    # ============================================
    # Admin API (Feature Flag 控制)
    # 参考设计: docs/plans/precious-tinkering-wave.md
    # ============================================
    # resource :candlestick_charts, only: :show
    # get 'discord_bot/get_order', to: 'discord_bot#get_order'
    # get 'discord_bot/get_order_link', to: 'discord_bot#get_order_link'
    # get 'discord_bot/get_item_link', to: 'discord_bot#get_item_link'
    # get 'discord_bot/get_market_link', to: 'discord_bot#get_market_link'
    # get 'discord_bot/get_instance_link', to: 'discord_bot#get_instance_link'
    # get 'skymavis_gateway/calldata', to: 'skymavis_gateway#calldata'

    # SIWE 认证路由 - 收口到 Client::Auth 边界
    get  '/nonce',     to: '/client/auth/siwe#nonce'
    options '/nonce', to: '/client/auth/siwe#nonce'
    post '/verify',    to: '/client/auth/siwe#verify'

    namespace :market do
      # ✅ 新增：市场列表 API（Trading Lite 支持）
      resources :markets, only: [:index], controller: '/client/market/markets'

      # Trading routes - 交易相关路由（新的组织结构）
      namespace :trading do
        resources :orders, only: [:create, :show], controller: '/client/market/trading/orders' do
          member do
            post 'update_status'
            post 'revalidate'  # 手动重试验证失败的订单
            get 'tooltip'
          end

          collection do
            get :list
            get :active_list
            get :user_list
            post :batch_update_offchain_status
            post :batch_update_status
            post :check_balance_status
            get :over_match_history
            get :balance_status_overview
          end
        end

        resources :trades, only: [:show], param: :trade_hash, controller: '/client/market/trading/trades' do
          collection do
            get :history
            get :statistics
            get :export
          end
        end

        resources :markets, only: [], controller: '/client/market/trading/markets' do
          member do
            get :summary
          end

          collection do
            get :summary_list
          end
        end
      end

      # NFT routes - NFT相关路由 (Client::NFT命名空间)
      namespace :nft do
        resources :tokens, only: [], controller: '/client/nft/tokens' do
          collection do
            post 'batch_instance_info'
            get 'root_status'
            get 'available_roots'
            get 'merkle_stats'
            get 'root', action: :get_root_by_item_id
            get 'root_info/:root_hash', action: :root_info, constraints: { root_hash: /0x[a-fA-F0-9]{64}/ }
          end

          member do
            get 'root'
            get 'proof'
            get 'verify'
            get 'instance_info'
            get 'merkle_proof'
            get 'validate_token'
            get 'latest_root'
            get 'validate_token_in_tree'
          end
        end
      end

      # Market item info routes (public)
      resources :items, only: [], controller: '/client/nft/items' do
        collection do
          get :info
          post :batch_info
        end

        member do
          get 'fungible_token'
        end
      end

      # Assets routes - 资产相关路由
      namespace :assets do
        resources :balances, only: [:index, :show], controller: '/client/market/assets/balances' do
          collection do
            post 'get_balances'
            get 'all_market_balances'
            get 'balance_by_item'
          end
        end
      end

      # Analytics routes - 数据分析路由
      namespace :analytics do
        get 'klines', to: '/client/market/analytics/klines#fetch', as: 'klines', defaults: { format: :json }
      end

      # 兼容性路由 - 保持原有URL结构，映射到新的Lumi控制器
      resources :orders, only: [:create, :show], controller: '/client/market/trading/orders' do
        member do
          post 'update_status'
          post 'revalidate'  # 手动重试验证失败的订单
          get 'tooltip'
        end

        collection do
          get :list
          get :active_list
          get :user_list
          post :batch_update_offchain_status
          post :batch_update_status
          post :check_balance_status
          get :over_match_history
          get :balance_status_overview
        end
      end

      resources :items, only: [], controller: '/client/nft/items' do
        collection do
          get :info
          get :mapping
        end

        member do
          get 'fungible_token', to: '/client/nft/tokens#get_fungible_token'
        end
      end

      resources :tokens, only: [], controller: '/client/nft/tokens' do
        collection do
          post 'batch_instance_info'
          get 'root_status'
          get 'available_roots'
          get 'merkle_stats'
          get 'root', action: :get_root_by_item_id
          get 'root_info/:root_hash', action: :root_info, constraints: { root_hash: /0x[a-fA-F0-9]{64}/ }
        end

        member do
          get 'root'
          get 'proof'
          get 'verify'
          get 'instance_info'
          get 'order_basis'
          get 'merkle_proof'
          get 'validate_token'
          get 'latest_root'
          get 'validate_token_in_tree'
        end
      end

      resources :balances, only: [:index, :show], controller: '/client/market/assets/balances' do
        collection do
          post 'get_balances'
          get 'all_market_balances'
          get 'balance_by_item'
        end
      end

      resources :trades, only: [:show], param: :trade_hash, controller: '/client/market/trading/trades' do
        collection do
          get :history
          get :statistics
          get :export
        end
      end

      get 'klines', to: '/client/market/analytics/klines#fetch', as: 'market_klines', defaults: { format: :json }
    end

    # ============================================
    # Explorer API - 公开查询（无需认证）
    # 类似区块链浏览器，查询物品/Instance/玩家/转移记录
    # ============================================
    namespace :explorer do
      # 物品查询
      resources :items, only: [:index, :show], controller: '/client/explorer/items' do
        member do
          get :instances  # 物品关联的Instance列表
          get :holders    # 物品持有者分布
          get :info       # 物品完整信息（含翻译）
        end

        collection do
          get :batch_info # 批量物品信息
          get :facets     # 筛选选项
        end
      end

      # Token实例查询
      resources :instances, only: [:index, :show], controller: '/client/explorer/instances' do
        member do
          get :balances   # Instance持有者余额
          get :transfers  # Instance转移历史
        end
      end

      # 玩家查询
      resources :players, only: [:index, :show], param: :address, controller: '/client/explorer/players' do
        member do
          get :balances   # 玩家持有的NFT
          get :transfers  # 玩家转移历史
        end
      end

      # 转移记录查询
      resources :transfers, only: [:index, :show], controller: '/client/explorer/transfers'

      # 配方查询
      resources :recipes, only: [:index, :show], controller: '/client/explorer/recipes' do
        collection do
          get 'tree/:item_id', action: :tree, as: :tree  # 递归配方树
          get :products  # 获取所有产物选项
        end
      end
    end
  end

  # ============================================
  # User API - 用户数据管理
  # 收藏夹、消息通知、偏好设置
  # ============================================
  scope path: '/api' do
    namespace :user, module: 'client/user' do
      # 收藏夹
      resources :favorites, param: :item_id, only: [:index, :destroy] do
        collection do
          put '', to: 'favorites#sync'
          post 'batch', to: 'favorites#batch_add'
          post ':item_id', to: 'favorites#create'
          delete '', to: 'favorites#clear'
          get 'count', to: 'favorites#count'
        end

        member do
          post 'toggle', to: 'favorites#toggle'
        end
      end

      # 偏好设置
      resources :preferences, only: [:index, :show, :update, :destroy] do
        collection do
          put 'batch', to: 'preferences#batch_update'
        end
      end

      # 消息通知
      resources :messages, only: [:index, :show, :destroy] do
        collection do
          put ':id/read', to: 'messages#mark_read'
          put ':id/archive', to: 'messages#archive'
          put 'read_all', to: 'messages#mark_all_read'
          get 'unread_count', to: 'messages#unread_count'
        end
      end
    end
  end

  # 维护模式路由 - 暂时注释（控制器已废弃）
  # unless Rails.env.test?
  #   match '*path', to: 'maintenance#show', via: :all
  # end
end
