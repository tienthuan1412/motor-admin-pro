# frozen_string_literal: true

module Motor
  module ApiQuery
    module Filter
      LIKE_FILTER_VALUE_REGEXP = /\A%?(.*?)%?\z/.freeze
      DISTINCT_RESTRICTED_COLUMN_TYPES = %i[json point].freeze

      module_function

      def call(rel, params)
        return rel if params.blank?

        normalized_params = normalize_params(Array.wrap(params))

        association_filters, direct_filters = extract_association_filters(rel.klass, normalized_params)

        rel = rel.filter(direct_filters) if direct_filters.present?

        association_filters.each do |assoc_name, column_filters|
          reflection = rel.klass.reflections[assoc_name.to_s]
          next unless reflection

          rel = rel.left_joins(assoc_name.to_sym)

          table = reflection.klass.arel_table

          column_filters.each do |column, conditions|
            conditions.each do |action, value|
              rel = rel.where(build_arel_condition(table, column, action, value))
            end
          end
        end

        rel = rel.distinct if can_apply_distinct?(rel)

        rel
      end

      def normalize_params(params)
        params.map do |item|
          next item if item.is_a?(String)
          next normalize_params(item) if item.is_a?(Array)

          item = item.to_unsafe_h if item.respond_to?(:to_unsafe_h)

          item.transform_values do |filter|
            if filter.is_a?(Hash)
              normalize_filter_hash(filter)
            else
              filter
            end
          end
        end.split('OR').product(['OR']).flatten(1)[0...-1]
      end

      def extract_association_filters(model, params)
        association_filters = {}
        direct_filters = []

        params.each do |item|
          if item.is_a?(String)
            direct_filters << item
            next
          end

          if item.is_a?(Array)
            nested_assoc, nested_direct = extract_association_filters(model, item)
            association_filters.merge!(nested_assoc)
            direct_filters << nested_direct if nested_direct.present?
            next
          end

          direct_items = {}

          item.each do |key, value|
            if model.reflections.key?(key.to_s)
              association_filters[key] = value
            else
              direct_items[key] = value
            end
          end

          direct_filters << direct_items if direct_items.present?
        end

        [association_filters, direct_filters]
      end

      def build_arel_condition(table, column, action, value)
        arel_column = table[column]

        case action
        when 'eq'
          value.nil? ? arel_column.eq(nil) : arel_column.eq(value)
        when 'neq'
          value.nil? ? arel_column.not_eq(nil) : arel_column.not_eq(value)
        when 'gt'
          arel_column.gt(value)
        when 'gte'
          arel_column.gteq(value)
        when 'lt'
          arel_column.lt(value)
        when 'lte'
          arel_column.lteq(value)
        when 'ilike'
          arel_column.matches(value)
        when 'contains'
          arel_column.matches("%#{value}%")
        else
          arel_column.eq(value)
        end
      end

      def normalize_filter_hash(hash)
        hash.each_with_object({}) do |(action, value), acc|
          new_action, new_value =
            if value.is_a?(Hash)
              [action, normalize_filter_hash(value)]
            else
              normalize_action(action, value)
            end

          acc[new_action] = new_value

          acc
        end
      end

      def can_apply_distinct?(rel)
        rel.columns.none? do |column|
          DISTINCT_RESTRICTED_COLUMN_TYPES.include?(column.type)
        end
      end

      def normalize_action(action, value)
        case action
        when 'includes'
          ['contains', value]
        when 'contains'
          ['ilike', value.sub(LIKE_FILTER_VALUE_REGEXP, '%\1%')]
        when 'starts_with'
          ['ilike', value.sub(LIKE_FILTER_VALUE_REGEXP, '\1%')]
        when 'ends_with'
          ['ilike', value.sub(LIKE_FILTER_VALUE_REGEXP, '%\1')]
        when 'eqnull'
          ['eq', nil]
        when 'neqnull'
          ['neq', nil]
        else
          [action, value]
        end
      end
    end
  end
end
