# encoding: utf-8

require_relative './member'

module CartoDB
  module Visualization
    class SupportTables

      def initialize(database_connection, config={})
        @database = database_connection
        @parent_id = config.fetch(:parent_id, nil)
        @parent_kind = config.fetch(:parent_kind, nil)
        @public_user_roles_list = config.fetch(:public_user_roles)
        reset
      end

      def reset
        @tables_list = nil
        @parent_table_name = nil
      end

      def parent
        @parent ||= @parent_id && Visualization::Member.new(id: @parent_id).fetch
      end

      def parent_table_name
        @parent_table_name || (parent && parent.name)
      end

      def parent_schema_name
        parent && parent.user.database_schema
      end

      def parent_database_name
        parent && parent.user.database_name
      end

      # Only intended to be used if from the Visualization Relator (who will set the parent)
      def load_actual_list(parent_name=nil)
        @parent_table_name = parent_name || @parent_table_name
        return [] if @parent_id.nil? || @parent_kind != Visualization::Member::KIND_RASTER
        table_data = @database.fetch(%Q{
          SELECT o_table_catalog AS catalog, o_table_schema AS schema, o_table_name AS name
          FROM raster_overviews
          WHERE r_table_catalog = '#{parent_database_name}'
          AND r_table_schema = '#{parent_schema_name}'
          AND r_table_name = '#{parent_table_name}'
        }).all

        table_data.nil? ? [] : table_data
      end

      def delete_all
        tables.each { |table|
          @database.execute(%Q{
            DROP TABLE "#{table[:schema]}"."#{table[:name]}"
          })
        }
        @database.run(%{SELECT CDB_DropOverviews('#{parent_table_name}'::regclass)})
      end

      # @param existing_parent_name String
      # @param new_parent_name String
      # @param recreate_relations Bool If true will recreate constraints and permissions from overviews
      # @param seek_parent_name String|nil If specified, seeking of tables will be performed using this name
      def rename(existing_parent_name, new_parent_name, recreate_relations=true, seek_parent_name=nil)
        begin
          schema = nil
          support_tables_new_names = []
          tables_list = tables(seek_parent_name)
          tables_list.each { |item|
            schema = item[:schema]
            new_support_table_name = item[:name].dup
            # CONVENTION: support_tables will always end in "_tablename", so we substitute using parent name
            new_support_table_name.slice!(-existing_parent_name.length, existing_parent_name.length)
            new_support_table_name = "#{new_support_table_name}#{new_parent_name}"

            @database.execute(%Q{
              ALTER TABLE "#{item[:schema]}"."#{item[:name]}" RENAME TO "#{new_support_table_name}"
            })

            support_tables_new_names.push(new_support_table_name)
          }
          renamed = true
        rescue
          renamed = false
        end

        if renamed && recreate_relations
          support_tables_new_names.each { |table_name|
            recreate_raster_constraints_if_exists(table_name, new_parent_name, schema)
            update_permissions(table_name, @public_user_roles_list, schema)
          }
        end

        @parent_table_name = seek_parent_name || existing_parent_name
        if parent_table_name
          # FIXME: this cannot work this way: by the time this is executed
          # the parent table has been renamed, so CDB_OVerviews(regclass)
          # will fail. We should have obtained the overview tables list
          # before renaming the table. Other solutions would be to have
          # a CDB_OVerviews(text) function that doesn't need the base table
          # to exist, or a CDB_RenameOverviews(text) function.
          begin
            overviews_schema = parent_schema_name
            overview_tables(parent_table_name).each do |overview_table|
              if overviews_schema
                qualified_table = %{"#{overviews_schema}"."#{overview_table}"}
              else
                qualified_table = %{"#{overview_table}"}
              end
              new_overview_table = overview_table.sub(parent_table_name, new_parent_name)
              @database.execute(%Q{
                ALTER TABLE "#{qualified_table}"
                RENAME TO "#{new_overview_table}"
              })
              update_permissions(new_overview_table, @public_user_roles_list, overviews_schema)
            end
          rescue
            renamed = false
          end
        end

        { success: renamed, names: support_tables_new_names }
      end

      def change_schema(new_schema, parent_table_name)
        tables.each { |item|
          @database.execute(%Q{
            ALTER TABLE "#{item[:schema]}"."#{item[:name]}"
            SET SCHEMA "#{new_schema}"
          })
          # Constraints are not automatically updated upon schema change or table renaming
          recreate_raster_constraints_if_exists(item[:name], parent_table_name, new_schema)
          update_permissions(item[:name], @public_user_roles_list, new_schema)
        }
        # @parent_table_name = parent_table_name
        # if parent_table_name
        #   # TODO: CDB_ChangeOverviewsSchema(...)
        #   overviews_schema = parent_schema_name
        #   overview_tables(parent_table_name).each do |overview_table|
        #     if overviews_schema
        #       qualified_table = %{"#{overviews_schema}"."#{overview_table}"}
        #     else
        #       qualified_table = %{"#{overview_table}"}
        #     end
        #     @database.execute(%Q{
        #       ALTER TABLE "#{qualified_table}"
        #       SET SCHEMA "#{new_schema}"
        #     })
        #     update_permissions(overview_table, @public_user_roles_list, new_schema)
        #   end
        # end
      end

      # For import purposes
      # @param new_list Array [ { :schema, :name } ]
      def tables=(new_list)
        @tables_list = new_list
      end

      private

      def tables(seek_parent_name=nil)
        @tables_list ||= load_actual_list(seek_parent_name)
      end

      def overview_tables(parent_table_name)
        begin
          overviews_data = @database.fetch(%{SELECT * FROM CDB_Overviews('#{parent_table_name}'::regclass)})
          if overviews_data
            overviews_data.map(:overview_table).to_a
          else
            []
          end
        rescue Sequel::DatabaseError => e
          raise unless e.to_s.match /relation .+ does not exist/
          []
        end
      end

      def update_permissions(overview_table_name, db_roles_list, schema)
        overviews = @database.fetch(%Q{
          SELECT o_table_name, o_table_schema
          FROM raster_overviews
          WHERE o_table_name = '#{overview_table_name}'
          AND o_table_schema = '#{schema}'
        }).first
        return if overviews.nil?

        @database.transaction do
          db_roles_list.each { |role_name|
            @database.execute(%Q{
              GRANT SELECT ON TABLE "#{overviews[:o_table_schema]}"."#{overviews[:o_table_name]}" TO "#{role_name}"
            })
          }
        end
      end

      # @see http://postgis.net/docs/manual-dev/using_raster_dataman.html#RT_Raster_Overviews
      def recreate_raster_constraints_if_exists(overview_table_name, raster_table_name, schema)
        constraint = @database.fetch(%Q{
          SELECT o_table_name, o_raster_column, r_table_name, r_raster_column, overview_factor
          FROM raster_overviews
          WHERE o_table_name = '#{overview_table_name}'
          AND o_table_schema = '#{schema}'
        }).first
        return if constraint.nil?

        @database.transaction do
          # @see http://postgis.net/docs/RT_DropOverviewConstraints.html
          @database.execute(%Q{
            SELECT DropOverviewConstraints('#{schema}', '#{constraint[:o_table_name]}',
                                           '#{constraint[:o_raster_column]}')
          })
          # @see http://postgis.net/docs/manual-dev/RT_AddOverviewConstraints.html
          @database.execute(%Q{
            SELECT AddOverviewConstraints('#{schema}', '#{constraint[:o_table_name]}',
                                          '#{constraint[:o_raster_column]}', '#{schema}', '#{raster_table_name}',
                                          '#{constraint[:r_raster_column]}', #{constraint[:overview_factor]});
          })
        end
      end

    end
  end
end
