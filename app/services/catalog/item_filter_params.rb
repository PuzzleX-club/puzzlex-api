# frozen_string_literal: true

module Catalog
  class ItemFilterParams
    def self.from_params(params)
      new(params).to_h
    end

    def initialize(params)
      @params = params
    end

    def to_h
      {
        use_levels: parse_array_param(@params[:use_levels])&.map(&:to_i),
        talent_ids: parse_array_param(@params[:talent_ids])&.map(&:to_i),
        item_types: parse_array_param(@params[:item_types])&.map(&:to_i)
      }
    end

    private

    def parse_array_param(param)
      return nil if param.blank?

      if param.is_a?(Array)
        param
      else
        param.split(',').map(&:strip).reject(&:empty?)
      end
    end
  end
end
