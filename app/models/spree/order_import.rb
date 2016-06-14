require 'csv'
require 'json'

module Spree
  class OrderError < StandardError; end;
  class ImportError < StandardError; end;
  class OrderImport < ActiveRecord::Base

    has_attached_file :data_file, path: ":rails_root/lib/etc/order_data/data-files/:basename.:extension", url: ":rails_root/lib/etc/order_data/data-files/:basename.:extension"
    validates_attachment :data_file, presence: true, content_type: { content_type: "text/csv" }
    # after_destroy :destroy_orders
    serialize :order_ids, Array

    state_machine initial: :created do
      event :start do
        transition to: :started, from: :created
      end
      event :complete do
        transition to: :completed, from: :started
      end
      event :failure do
        transition to: :failed, from: :started
      end
      before_transition to: [:failed] do |import|
        import.product_ids = []
        import.failed_at = Time.now
        import.completed_at = nil
      end
      before_transition to: [:completed] do |import|
        import.failed_at = nil
        import.completed_at = Time.now
      end
    end

    def orders
      Order.where :number => order_ids
    end

    # def destroy_orders
    #   orders.destroy_all
    # end

    def state_datetime
      if failed?
        failed_at
      elsif completed?
        completed_at
      else
        Time.now
      end
    end

    def import_data!(_transaction=true)
        start
        if _transaction
          transaction do
            _import_data
          end
        else
          _import_data
        end
    end

    def _import_data
      begin
        @orders_before_import = Spree::Order.all
        @numbers_of_orders_before_import = @orders_before_import.map(&:number)

        rows = CSV.read(self.data_file.path)
        col = get_column_mappings(rows[0])

        previous_row = nil
        previous_order_information = nil

        rows[1..-1].each_with_index do |row, index|
          order_information = assign_col_row_mapping(row, col)
          order_information = validate_and_sanitize(order_information)
          next if @numbers_of_orders_before_import.include?(order_information[:order_id])
          # next unless Spree::Variant.find_by_sku(order_information[:sku])
          order_data = get_order_hash(order_information)
          order_data[:bill_address_attributes] = get_address_hash(order_information, 'bill')
          order_data[:ship_address_attributes] = get_address_hash(order_information, 'ship')
          order_data = add_custom_order_fields(order_information, order_data)
          user = Spree::User.find_by_email(order_information[:email]) || Spree::User.new(email: order_information[:email])

          if previous_row == nil
            previous_row = order_data
            previous_order_information = order_information
          elsif previous_row[:number] == order_data[:number]
            order_data[:line_items_attributes]
            attributes = [:line_items_attributes, :payments_attributes, :adjustments_attributes, :shipments_attributes]
            attributes.each do |attribute|
              if previous_row[attribute]
                if order_data[attribute] && (attribute != :shipments_attributes or order_data[:shipments_attributes][:tracking].present?)
                  previous_row[attribute].concat(order_data[attribute])
                end
              else
                previous_row[attribute] = order_data[attribute]
              end
            end
          else
            order = Spree::Core::Importer::Order.import(user, previous_row)
            if order
              order_ids << order.number
              after_order_created(previous_order_information, order)
            end
            previous_row = order_data
            previous_order_information = order_information
          end

          if rows.count == index+2
            order = Spree::Core::Importer::Order.import(user, previous_row)
            if order
              order_ids << order.number
              after_order_created(previous_order_information, order)
            end
          end
        end
      end

      # Finished Importing!
      complete
      return [:notice, "Orders data was successfully imported."]
    end

    private
      # get_column_mappings
      # This method attempts to automatically map headings in the CSV files
      # with fields in the product and variant models.
      # If the headings of columns are going to be called something other than this,
      # or if the files will not have headings, then the manual initializer
      # mapping of columns must be used.
      # @return a hash of symbol heading => column index pairs
      def get_column_mappings(row)
        mappings = {}
        row.each_with_index do |heading, index|
          # Stop collecting headings, if heading is empty
          if not heading.blank?
            mappings[heading.downcase.gsub(/\A\s*/, '').chomp.gsub(/\s/, '_').to_sym] = index
          else
            break
          end
        end
        mappings
      end

      def assign_col_row_mapping(row, col)
        order_information = {}
        col.each do |key, value|
          #Trim whitespace off the beginning and end of row fields
          row[value].try :strip!
          order_information[key] = row[value]
        end
        order_information
      end

      def validate_and_sanitize(order_information)
        # this method can be overiden to include custom logic
        # order_information[:completed_at] = DateTime.strptime(order_information[:completed_at], "%d/%m/%y %H:%M")
        order_information[:completed_at] = order_information[:completed_at] || Time.now
        order_information[:quantity] = order_information[:quantity] || 1
        order_information
      end

      def get_order_hash(order_information)
        {
          number: order_information[:order_id],
          email: order_information[:email],
          completed_at: order_information[:completed_at],
          currency: order_information[:currency],
          channel: order_information[:channel],
          line_items_attributes: create_params_hash_from_json(order_information[:line_items]),
          payments_attributes: [
            { amount: order_information[:grand_total], payment_method: order_information[:payment_method], state: order_information[:payment_state], created_at: order_information[:payment_created_at]}
          ],
          adjustments_attributes: [
            {amount: order_information[:adjustment_amount], label: order_information[:adjustment_label]}
          ],
          shipments_attributes: [{
            tracking: order_information[:tracking],
            stock_location: order_information[:stock_location] || 'default',
            shipped_at: order_information[:shipped_at],
            shipping_method: order_information[:shipping_method] || 'default',
            cost: order_information[:shipping_cost],
            inventory_units: create_params_hash_from_json(order_information[:inventory_items]),
          }]
        }
      end

      def get_address_hash(order_information, type)
        {
          firstname: order_information["#{type}_firstname".to_sym],
          lastname: order_information["#{type}_lastname".to_sym],
          phone: order_information["#{type}_phone".to_sym],
          address1: order_information["#{type}_address1".to_sym],
          address2: order_information["#{type}_address2".to_sym],
          city: order_information["#{type}_city".to_sym],
          state: { 'name'=> order_information["#{type}_state".to_sym] },
          zipcode: order_information["#{type}_zipcode".to_sym],
          country: { 'name'=> order_information["#{type}_country".to_sym]}
        }
      end

      def add_custom_order_fields(order_information, order_data)
        # this method can be overiden to include custom logic
        # eg. order_data[:shipments_attributes] = nil
        order_data[:adjustments_attributes] = nil unless order_information[:adjustment_amount] and order_information[:adjustment_label]
        order_data
      end

      def after_order_created(order_information, order)
        # this method can be overiden to include custom logic
        # eg. order.shipments.first.update(tracking: order_information[:tracking])
        order.cancel if order_information[:status] == "canceled"
      end

      def create_params_hash_from_json array_of_line_items
        JSON.parse(array_of_line_items).each {|h| h.symbolize_keys!}
      end

  end
end
