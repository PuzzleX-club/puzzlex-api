# frozen_string_literal: true

module User
  # 用户偏好服务
  # 提供偏好设置的 CRUD 操作
  class PreferenceService
    class << self
      DEFAULT_PROJECT = Rails.application.config.x.project.default_key.freeze

      # 获取单个偏好值
      # @param user [Accounts::User] 用户对象
      # @param key [String] 偏好键名
      # @param project [String] 项目标识
      # @return [Object, nil] 偏好值，不存在时返回 nil
      def get_preference(user, key, project = DEFAULT_PROJECT)
        Accounts::UserPreference.get_preference(user.id, project, key)
      end

      # 设置单个偏好值
      # @param user [Accounts::User] 用户对象
      # @param key [String] 偏好键名
      # @param value [Object] 偏好值
      # @param project [String] 项目标识
      # @param version [Integer] 数据版本
      # @return [Accounts::UserPreference] 保存的偏好记录
      def set_preference(user, key, value, project = DEFAULT_PROJECT, version: 1)
        Accounts::UserPreference.set_preference(user.id, project, key, value, version: version)
      end

      # 批量获取偏好
      # @param user [Accounts::User] 用户对象
      # @param project [String] 项目标识
      # @return [Hash] 偏好键值对
      def get_all_preferences(user, project = DEFAULT_PROJECT)
        Accounts::UserPreference.preferences_for_user(user.id, project)
      end

      # 批量设置偏好
      # @param user [Accounts::User] 用户对象
      # @param preferences [Hash] 偏好键值对
      # @param project [String] 项目标识
      # @param version [Integer] 数据版本
      def batch_set_preferences(user, preferences, project = DEFAULT_PROJECT, version: 1)
        Accounts::UserPreference.batch_set_preferences(user.id, project, preferences)
      end

      # 删除偏好
      # @param user [Accounts::User] 用户对象
      # @param key [String] 偏好键名
      # @param project [String] 项目标识
      # @return [Integer] 删除的记录数
      def delete_preference(user, key, project = DEFAULT_PROJECT)
        Accounts::UserPreference.delete_preference(user.id, project, key)
      end

      # 获取或初始化默认偏好
      # @param user [Accounts::User] 用户对象
      # @param key [String] 偏好键名
      # @param defaults [Object] 默认值
      # @param project [String] 项目标识
      # @return [Object] 偏好值
      def get_or_initialize(user, key, defaults, project = DEFAULT_PROJECT)
        value = get_preference(user, key, project)
        return value if value.present?

        set_preference(user, key, defaults, project)
        defaults
      end

      # 更新偏好（仅当值存在时）
      # @param user [Accounts::User] 用户对象
      # @param key [String] 偏好键名
      # @param value [Object] 偏好值
      # @param project [String] 项目标识
      # @return [Boolean] 是否更新成功
      def update_if_exists(user, key, value, project = DEFAULT_PROJECT)
        pref = Accounts::UserPreference.find_by(user_id: user.id, project: project, key: key)
        return false unless pref

        pref.update!(value: value)
        true
      end
    end
  end
end
