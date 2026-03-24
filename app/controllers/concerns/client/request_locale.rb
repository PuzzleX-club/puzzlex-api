# frozen_string_literal: true

module Client
  module RequestLocale
    extend ActiveSupport::Concern

    # 统一的 locale 获取方法，供所有 Client 模块使用
    def request_locale
      @request_locale ||= begin
        # 优先使用 URL 参数
        return params[:locale] if params[:locale].present?

        # 其次使用 Accept-Language 头
        accept_language = request.env['HTTP_ACCEPT_LANGUAGE']
        return I18n.default_locale if accept_language.blank?

        # 解析 Accept-Language: "zh-CN,zh;q=0.9,en;q=0.8"
        locales = accept_language.split(',').map { |l| l.split(';').first.strip }

        # 查找第一个支持的语言
        found = locales.find { |locale| supported_locales.include?(locale) }
        found || I18n.default_locale
      end
    end

    private

    def supported_locales
      @supported_locales ||= Rails.application.config.i18n.available_locales.map(&:to_s)
    end
  end
end
