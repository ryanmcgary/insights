class Explorer::Controller < Controller
  before_action :assure_insights_admin_access

  def index
    render_props_or_component
  end

  def structure
    render json: get_structure
  end

  def results
    conn = TargetDatabase.connection

    database_adapter = TargetDatabase.connection.adapter_name.downcase.to_sym

    percentages = !!params[:percentages]

    sort_column = params[:sort]
    sort_descending = false

    if sort_column.present? && sort_column.start_with?('-')
      sort_column = sort_column[1..-1]
      sort_descending = true
    end

    columns = params[:columns].map { |s| s }
    structure = get_structure

    filter = (params[:filter] || [])

    base_model_name = columns.first.split('.').first

    columns_to_include = (columns + filter.map { |v| v[:key] }).uniq

    if structure[base_model_name].blank?
      render json: { error: "Base model #{base_model_name} not found" } and return
    end

    if columns.select { |s| s.split('.').first != base_model_name}.count > 0
      render json: { error: "Each selected value must have the same base model!" } and return
    end

    table_name = structure[base_model_name]['table_name']
    first_join_name = '$T0'

    joins = {
      base_model_name => {
        name: first_join_name,
        sql: "FROM \"#{table_name}\" AS \"#{first_join_name}\""
      }
    }

    table_counter = 0
    value_counter = 0

    value_list = []
    all_column_list = []

    columns_to_include.each do |column|
      path, transform, aggregate = column.gsub('$', '!').split('!', 3)

      # always starting the traverse from the base model
      pointer = structure[base_model_name]

      traversed_path = []
      join_name = first_join_name

      local_path = path.split('.')[1..-1]
      local_path.each do |key|
        if pointer['columns'][key] || pointer['custom'][key]
          data = pointer['columns'][key] || pointer['custom'][key]
          sql = "\"#{join_name}\".\"#{key}\""
          sql_before_transform = nil

          if pointer['custom'][key]
            sql = (data['sql'] || '').gsub('$$.', "\"#{join_name}\".")
          end

          if data['type'].to_s == 'time'
            if database_adapter.in? %i(postgresql postgis)
              sql = "(#{sql} at time zone 'UTC' at time zone '#{Time.zone.name}')"
            end

            if transform.present? && transform.in?(%w(hour day week month quarter year))
              sql_before_transform = sql
              sql = date_transform(transform, sql, database_adapter)
            end
          end

          if aggregate.present? && aggregate.in?(%w(count sum min max avg))
            sql = "#{aggregate}(#{aggregate == 'count' ? 'distinct ' : ''}#{sql})"
          end

          value_object = {
            column: column,
            path: path,
            table: join_name,
            key: key,
            sql: sql,
            sql_before_transform: sql_before_transform,
            alias: columns.include?(column) ? "$V#{value_counter}" : '',
            type: data['type'].to_s,
            url: data['url'],
            model: pointer['model'],
            transform: transform,
            aggregate: aggregate.present? ? aggregate : nil,
            index: data['index']
          }

          all_column_list << value_object

          if columns.include?(column)
            value_list << value_object
            value_counter += 1
          end

        elsif pointer['links']['incoming'][key] || pointer['links']['outgoing'][key]
          link_data = pointer['links']['incoming'][key] || pointer['links']['outgoing'][key]
          pointer = structure[link_data['model']]

          traversed_path << key

          last_join_name = join_name

          if joins[traversed_path.join('.')].present?
            join_name = joins[traversed_path.join('.')][:name]
          else
            table_counter += 1
            join_name = "$T#{table_counter}"

            joins[traversed_path.join('.')] = {
              name: join_name,
              sql: "LEFT JOIN \"#{pointer['table_name']}\" \"#{join_name}\" ON (\"#{join_name}\".\"#{link_data['model_key']}\" = \"#{last_join_name}\".\"#{link_data['my_key']}\")"
            }
          end
        end
      end
    end

    from_array = joins.map do |key, join|
      join[:sql]
    end

    where_sql = ''
    having_sql = ''

    if filter.present?
      where_conditions = []
      having_conditions = []
      filter.each do |filter_object|
        column = filter_object[:key]
        filter_condition = filter_object[:value]

        conditions = []
        filter_value = all_column_list.select { |v| v[:column] == column }.first
        if filter_value.present?
          if filter_condition == 'null'
            if filter_value[:type] == 'string'
              conditions << "((#{filter_value[:sql]}) IS NULL OR (#{filter_value[:sql]}) = '')"
            else
              conditions << "(#{filter_value[:sql]}) IS NULL"
            end
          elsif filter_condition == 'not null'
            if filter_value[:type] == 'string'
              conditions << "((#{filter_value[:sql]}) IS NOT NULL AND (#{filter_value[:sql]}) != '')"
            else
              conditions << "(#{filter_value[:sql]}) IS NOT NULL"
            end
          elsif filter_condition.start_with? 'in:'
            string = filter_condition[3..-1]
            conditions << "(#{filter_value[:sql]}) in (#{string.split(/, ?/).map { |s| conn.quote(s) }.join(', ')})"
          elsif filter_condition.start_with? 'not_in:'
            string = filter_condition[7..-1]
            conditions << "(#{filter_value[:sql]}) not in (#{string.split(/, ?/).map { |s| conn.quote(s) }.join(', ')})"
          elsif filter_condition.start_with? 'equals:'
            string = filter_condition[7..-1]

            if database_adapter == :sqlite && filter_value[:type] == 'boolean'
              conditions << "(#{filter_value[:sql]}) = #{conn.quote(string == 'true' ? 't' : 'f')}"
            else
              conditions << "(#{filter_value[:sql]}) = #{conn.quote(string)}"
            end

          elsif filter_condition.start_with? 'contains:'
            string = filter_condition[9..-1]

            if database_adapter.in? %i(postgresql postgis)
              conditions << "(#{filter_value[:sql]}) ilike #{conn.quote('%' + string + '%')}"
            else
              conditions << "(#{filter_value[:sql]}) like #{conn.quote('%' + string + '%')}"
            end
          elsif filter_condition.start_with? 'between:'
            start, finish = filter_condition[8..-1].split(':')
            if start != '' && !start.nil?
              conditions << "(#{filter_value[:sql]}) >= #{conn.quote(start)}"
            end
            if finish != '' && !finish.nil?
              conditions << "(#{filter_value[:sql]}) <= #{conn.quote(finish)}"
            end
          elsif filter_condition.start_with? 'date_range:'
            _, start, finish = filter_condition.split(':')
            if start.present?
              date = start.to_date rescue nil
              if date.present?
                conditions << "(#{filter_value[:sql]}) >= #{conn.quote(date.to_s)}"
              end
            end
            if finish.present?
              date = finish.to_date rescue nil
              if date.present?
                conditions << "(#{filter_value[:sql]}) < #{conn.quote((date + 1.day).to_s)}"
              end
            end
          end
        end

        if filter_value[:aggregate]
          having_conditions += conditions
        else
          where_conditions += conditions
        end
      end
      if where_conditions.present?
        where_sql = "WHERE #{where_conditions.join(' AND ')}"
      end
      if having_conditions.present?
        having_sql = "HAVING #{having_conditions.join(' AND ')}"
      end
    end

    # group

    group_sql = ''
    group_parts = []
    any_aggregate = all_column_list.select { |v| v[:aggregate].present? }.present?

    if any_aggregate
      group_parts = all_column_list.select { |v| v[:aggregate].blank? }.map { |v| v[:sql] }
      if group_parts.present?
        group_sql = "GROUP BY #{group_parts.join(',')}"
      end
    end

    # sort / order

    sort_sql = ""
    sort_parts = []

    if sort_column.present?
      sort_value = all_column_list.select { |v| v[:column] == sort_column }.first
      if sort_value.present? && sort_value[:alias].present?
        sort_parts << "\"#{sort_value[:alias]}\" #{sort_descending ? 'DESC' : 'ASC'}"
      end
    end

    first_primary = structure[base_model_name]['columns'].select { |k, v| v['index'].to_s == 'primary' }.first.try(:first)

    if first_primary.present? && !any_aggregate
      sort_parts << "\"#{first_join_name}\".\"#{first_primary}\" ASC"
    end

    if sort_parts.present?
      sort_sql = "ORDER BY #{sort_parts.join(', ')}"
    end

    # get the count

    count = 1

    count_sql = "SELECT count(*) as count #{from_array.join(' ')} #{where_sql} #{group_sql} #{having_sql}"
    if group_sql.present?
      count_sql = "SELECT count(*) as count FROM (#{count_sql}) AS t"
    end

    any_non_aggregate = all_column_list.select { |v| v[:aggregate].blank? }.present?
    if any_non_aggregate
      count_results = conn.execute(count_sql)
      count = count_results.first['count']
    end

    # limit

    offset = params[:offset].try(:to_i) || 0
    limit = params[:limit].try(:to_i) || 25

    if params[:export] == 'xlsx'
      offset = 0
      limit = [count, 65535].min
    end

    # get the results

    value_array = value_list.each_with_index.map do |value, i|
      "#{value[:sql]} AS \"#{value[:alias]}\""
    end

    results_sql = "SELECT #{value_array.join(', ')} #{from_array.join(' ')} #{where_sql} #{group_sql} #{having_sql} #{sort_sql} LIMIT #{limit} OFFSET #{offset}"

    final_columns = value_list.map { |v| v[:column] }

    results = conn.execute(results_sql)
    final_results = results.map do |row|
      final_columns.count.times.map { |i| row["$V#{i}"] }
    end

    # graph

    graph = nil
    graph_time_filter = params[:graphTimeFilter] || 'last-60'
    graph_cumulative = !!params[:graphCumulative]

    begin
      time_columns = value_list.select { |v| v[:type] == 'time' && v[:aggregate].blank? }
      aggregate_columns = value_list.select { |v| v[:aggregate].present? }

      facet_columns = []
      if params[:facetsColumn].present?
        facet_columns = value_list.select { |v| v[:type].in?(%w(string boolean)) && v[:aggregate].blank? && v[:column] == params[:facetsColumn] }.first(1)
      end
      facet_count = params[:facetsCount].present? ? params[:facetsCount].to_i : 6

      if aggregate_columns.count >= 1 && time_columns.count == 1 && facet_columns.count <= 1
        # graph time
        time_column = time_columns.first

        time_group = time_column[:transform].present? ? time_column[:transform].to_sym : :day
        first_date, last_date = get_times_from_string(graph_time_filter, 0, time_group)

        time_columns = time_columns.map do |v|
          v.merge({ transform: time_group.to_s, sql: date_transform(time_group.to_s, v[:sql_before_transform], database_adapter) })
        end

        graph_sort_sql = "ORDER BY #{time_column[:sql]}"
        graph_where_sql = first_date.blank? || last_date.blank? ? where_sql : "#{where_sql.present? ? "#{where_sql} AND " : 'WHERE '}#{time_column[:sql]} >= #{conn.quote(first_date.to_s)} AND #{time_column[:sql]} <= #{conn.quote(last_date.to_s)}"

        graph_group_parts = (time_columns + aggregate_columns + facet_columns).select { |v| v[:aggregate].blank? }.map { |v| v[:sql] }
        graph_group_sql = "GROUP BY #{graph_group_parts.join(',')}"

        # facets
        facet_column = facet_columns.first
        facet_values = []

        if facet_column.present?
          facet_select = "#{facet_column[:sql]} AS facet_value, count(#{facet_column[:sql]}) as facet_count"
          facet_sort_sql = "ORDER BY facet_count desc"
          facet_sql = "SELECT #{facet_select} #{from_array.join(' ')} #{graph_where_sql} #{graph_group_sql} #{having_sql} #{facet_sort_sql}"
          facet_sql = "SELECT t.facet_value, sum(t.facet_count) FROM (#{facet_sql}) t GROUP BY t.facet_value ORDER BY sum(t.facet_count) DESC LIMIT #{facet_count + 1}"
          facet_results = conn.execute(facet_sql)
          facet_values = facet_results.map { |r| r['facet_value'] }

          facet_other = facet_values.include?('Other') ? '__OTHER__' : 'Other'

          if facet_column[:type] == 'string'
            if facet_values.present?
              if facet_values.count > facet_count
                facet_values = facet_values.first(facet_count)
                facet_columns = [
                  facet_column.merge({
                    sql: "(CASE WHEN #{facet_column[:sql]} IN (#{facet_values.map { |s| conn.quote(s) }.join(', ')}) THEN #{facet_column[:sql]} ELSE #{conn.quote(facet_other)} END)"
                  })
                ]
                facet_values << facet_other

                if any_aggregate
                  graph_group_parts = (time_columns + aggregate_columns + facet_columns).select { |v| v[:aggregate].blank? }.map { |v| v[:sql] }
                  if graph_group_parts.present?
                    graph_group_sql = "GROUP BY #{graph_group_parts.join(',')}"
                  end
                end
              end
            else
              facet_columns = []
            end
          end
        end

        # graph results

        graph_values = time_columns + aggregate_columns + facet_columns

        graph_value_array = graph_values.each_with_index.map do |value, i|
          "#{value[:sql]} AS \"#{value[:alias]}\""
        end

        graph_sql = "SELECT #{graph_value_array.join(', ')} #{from_array.join(' ')} #{graph_where_sql} #{graph_group_sql} #{having_sql} #{graph_sort_sql} LIMIT 10000"

        result_hash = {}

        graph_results = conn.execute(graph_sql)
        graph_results.each do |r|
          date = r[time_column[:alias]].to_date.to_s
          result_hash[date] ||= { time: date }

          aggregate_columns.each do |aggregate_column|
            key = aggregate_column[:column]
            facet_columns.each do |c|
              key += "$$#{r[c[:alias]]}"
            end
            result_hash[date][key] = r[aggregate_column[:alias]]
          end
        end

        all_keys = []
        aggregate_columns.each do |aggregate_column|
          key = aggregate_column[:column]
          if facet_values.present?
            facet_values.each do |v|
              all_keys << "#{key}$$#{v}"
            end
          else
            all_keys << key
          end
        end

        first_date = result_hash.keys.min.try(:to_date) if first_date.blank?
        last_date = result_hash.keys.max.try(:to_date) if last_date.blank?

        # add empty rows
        all_dates = []

        if first_date.present? && last_date.present?
          (first_date..last_date).each do |date|
            next if time_group == :year && (date.day != 1 || date.month != 1)
            next if time_group == :quarter && !(date.day == 1 && date.month.in?([1, 4, 7, 10]))
            next if time_group == :month && date.day != 1
            next if time_group == :week && date.wday != 1

            all_dates << date
          end
        end

        if all_dates.present?
          empty_hash = all_keys.map { |k| [k, 0] }.to_h

          all_dates.each do |date|
            if result_hash[date.to_s].blank?
              result_hash[date.to_s] = { time: date.to_s }.merge(empty_hash)
            else
              all_keys.each do |key|
                if result_hash[date.to_s][key].nil?
                  result_hash[date.to_s][key] = 0
                end
              end
            end
          end
        end

        if graph_cumulative
          count_hash = all_keys.map { |k| [k, 0] }.to_h
          all_dates.each do |date|
            all_keys.each do |key|
              count_hash[key] += result_hash[date.to_s][key].try(:to_f) || 0
              result_hash[date.to_s][key] = count_hash[key]
            end
          end
        end

        graph = {
          meta: graph_values.map { |v| v.slice(:column, :path, :type, :url, :key, :model, :aggregate, :transform, :index) },
          keys: all_keys,
          facets: facet_values,
          results: result_hash.values.sort_by { |h| h[:time] },
          timeGroup: time_group.to_s
        }
      end
    rescue => e
      if Rails.env.development?
        raise e
      else
        Bugsnag.notify(e)
        facet_columns = []
      end
    end

    response = {
      success: true,
      columns: final_columns,
      columnsMeta: all_column_list.map { |v| [v[:column], v.slice(:column, :path, :type, :url, :key, :model, :aggregate, :transform, :index)] }.to_h,
      results: final_results,
      graph: graph,
      count: count,
      offset: offset,
      limit: limit,
      sort: sort_column.present? ? "#{sort_descending ? '-' : ''}#{sort_column}" : nil,
      filter: filter,
      facetsColumn: params[:facetsColumn] || nil,
      facetsCount: facet_count,
      graphTimeFilter: graph_time_filter,
      graphCumulative: graph_cumulative,
      percentages: percentages
    }

    if params[:export] == 'xlsx'
      export_xlsx response
    elsif params[:export] == 'pdf'
      export_pdf response
    else
      render json: response
    end

  rescue ActiveRecord::StatementInvalid => e
    if e.message.split("\n").first.include?('canceling statement due to statement timeout')
      render json: {
        error: 'Database Operation Timeout'
      }
    else
      raise e
    end
  end

protected

  def get_structure
    structure = YAML::load_file(INSIGHTS_EXPORT_PATH)
    structure = structure.select { |k, v| v['enabled'] }.map do |k, v|
      [k, v.merge({ 'columns' => v['columns'].select { |_, vv| vv.present? } })]
    end.to_h
  end

  def date_transform(transform, sql, database_adapter)
    if database_adapter.in? %i(postgis postgresql)
      "date_trunc('#{transform}', #{sql})::date"
    elsif database_adapter.in? %i(sqlite)
      if transform == 'day'
        "date(#{sql})"
      else
        "datetime(#{sql}, 'start of #{transform}')"
      end
    else
      sql
    end
  end

  def get_times_from_string(time_filter, smooth = 0, time_group = :day)
    if time_filter =~ /\A20[0-9][0-9]\z/
      year = time_filter.to_i
      first_date = "#{year}-01-01".to_date - (smooth.present? ? smooth.to_i.days : 0)
      last_date = "#{year+1}-01-01".to_date - 1.day
    elsif time_filter == 'this-month-so-far'
      first_date = Time.new.to_date - Time.new.day + 1.day
      last_date = Time.new.to_date
    elsif time_filter == 'this-month'
      first_date = Time.new.to_date - Time.new.day + 1.day
      last_date = first_date + 1.month - 1.day
    elsif time_filter == 'last-month'
      first_date = Time.new.to_date - Time.new.day + 1.day - 1.month
      last_date = first_date + 1.month - 1.day
    elsif time_filter =~ /\Alast-([0-9]+)\z/
      day_count = time_filter.split('last-').last.to_i
      day_count += smooth.to_i if smooth.present?
      first_date = day_count.days.ago.to_date
      if time_group == :month
        first_date -= (first_date.day - 1).days
      elsif time_group == :week
        wday = first_date.wday
        first_date -= (wday == 0 ? 6 : wday - 1).days
      end
      last_date = Time.new.to_date
    end
    [first_date, last_date]
  end

  def export_xlsx(response)
    @package = Axlsx::Package.new
    @package.workbook.add_worksheet(name: params[:exportTitle].present? ? "#{params[:exportTitle]} Results" : "Results") do |sheet|
      sheet.add_row response[:columns].map { |c| c.split('.')[1..-1].join('.') }
      response[:results].each do |row|
        sheet.add_row row
      end
    end

    if response[:graph].present?
      facet_column_key = facets.present? ? keys.select { |k| k.include?('$$') }.first.split('$$')[0] : nil
      skip = facets.present? ? facet_column_key.length + 2 : longest_common_prefix(keys).length

      @package.workbook.add_worksheet(name: params[:exportTitle].present? ? "#{params[:exportTitle]} Graph" : "Graph") do |sheet|
        keys = [:time] + response[:graph][:keys]
        sheet.add_row [:time] + response[:graph][:keys].map { |k| k[skip..-1] }
        response[:graph][:results].each do |row|
          sheet.add_row keys.map { |k| row[k] }
        end
      end
    end

    tempfile = Tempfile.new(['export-', '.xlsx'])
    @package.serialize(tempfile)

    send_file tempfile, type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet', disposition: 'attachment', filename: "#{export_title}.xlsx"
  end

  def export_pdf(response)
    contents = ''
    contents += "<html><head><meta charset='utf-8' /><style>\n"
    contents += "body { font-family: 'Arial' }\n"
    contents += "tr, td, th, tbody, thead, tfoot { page-break-inside: avoid !important; }\n"
    contents += "td { border-bottom: 1px solid #eee; }\n"
    contents += "</style></head><body>\n"

    contents += "<h1>#{export_title}</h1>"

    if response[:graph].present?
      contents += "#{params[:svg]}<br/><br/>\n"
      colors = ['#1f77b4', '#ff7f0e', '#2ca02c', '#d62728', '#9467bd', '#8c564b', '#e377c2', '#7f7f7f', '#bcbd22', '#17becf']

      contents += "<table style='width:100%'><thead><tr>"
      contents += "<th style='color:white;background:black;'>#{response[:graph][:timeGroup].capitalize}</th>"

      keys = response[:graph][:keys]
      facets = response[:graph][:facets]

      facet_column_key = facets.present? ? keys.select { |k| k.include?('$$') }.first.split('$$')[0] : nil
      facet_column = facet_column_key.present? ? response[:graph][:meta].select { |r| r[:column] == facet_column_key }.first : nil
      aggregate = facet_column.present? ? facet_column[:aggregate] : nil

      skip = facets.present? ? facet_column_key.length + 2 : longest_common_prefix(keys).length

      keys.each_with_index do |key, index|
        title = key[skip..-1]
        title = title.gsub('.id!!', ' ').gsub('id!!', ' ').gsub('_', ' ').gsub('!!', ' ').gsub('!', ' ')
        title = 'Total' if title == ''
        contents += "<th style='color:white;background:#{colors[index] || 'black'}'>#{CGI::escapeHTML(title)}</th>"
      end

      if facets.present? && aggregate.present? && aggregate != 'avg'
        contents += "<th style='color:white;background:#888;'>#{aggregate.in?(%w(sum count)) ? 'Total' : aggreagete.capitalize}</th>"
      end

      contents += "</tr></thead><tbody>"

      response[:graph][:results].each do |row|
        contents += "<tr>"

        day = row[:time].to_date
        time_group = response[:graph][:timeGroup]

        if time_group == 'year'
          contents += "<td>#{day.year}</td>"
        elsif time_group == 'quarter'
          contents += "<td>Q#{(day.month / 3.0).ceil} #{day.year}</td>"
        elsif time_group == 'month'
          contents += "<td>#{day.to_s.split('-')[0..1].join('-')}</td>"
        elsif time_group == 'week'
          contents += "<td>#{day.to_s} - #{(day + 6.days).to_s}</td>"
        elsif time_group == 'day'
          contents += "<td>#{day.to_s}</td>"
        end

        total = nil

        column_tds = ''

        max = keys.map { |k| row[k] }.select { |v| !v.nil? }.max

        keys.each do |key|
          value = row[key].nil? ? 0 : row[key].to_f

          # for the "total" column, summing up all the facets per row
          if facets.present? && aggregate.present? && aggregate != 'avg'
            if aggregate == 'count' || aggregate == 'sum'
              total ||= 0
              total += value
            elsif aggregate == 'min'
              total = total.nil? ? value : [value, total].min
            elsif aggregate == 'max'
              total = total.nil? ? value : [value, total].max
            end
          end
          display = format_number(value, aggregate)
          if params[:percentages]
            percentage_value = (max != 0 ? 100.0 * value / max : 0).round
            if percentage_value != 100
              display = "#{display} <span style='color:#888;'>(#{percentage_value}%)</span>"
            end
          end
          column_tds += "<td style='text-align:right'>#{display}</td>"
        end

        contents += column_tds

        if facets.present? && aggregate.present? && aggregate != 'avg'
          contents += "<td style='text-align:right'>#{format_number(total.nil? ? 0 : total.round(2), aggregate)}</td>"
        end

        contents += "</tr>"
      end
      contents += "</tbody></table>"
    else
      contents += "<table style='width:100%'><thead><tr>"
      contents += response[:columns].map do |c|
        path, transform, aggregate = c.split('!', 3)
        header = [aggregate, transform, path.split('.')[1..-1].reverse.join(' < ')].select(&:present?).join(' ')
        "<th style='color:white;background:#888;'>#{CGI::escapeHTML(header)}</th>"
      end.join
      contents += "</tr></thead><tbody>"
      response[:results].each do |row|
        contents += "<tr>" + (row.map { |c| "<td>#{CGI::escapeHTML(c.to_s)}</td>" }.join) + "</tr>"
      end
      contents += "</tbody></table>"
    end

    contents += "</body></html>"

    pdf = WickedPdf.new.pdf_from_string(contents, pdf: "#{export_title}.pdf", footer: nil)

    send_data pdf, type: 'application/pdf', disposition: 'attachment', filename: "#{export_title}.pdf"
  end

  def export_title
    params[:exportTitle].present? ? params[:exportTitle] : "Insights Export #{Time.now}"
  end

  def longest_common_prefix(strs)
    return '' if strs.empty?
    min, max = strs.minmax
    idx = min.size.times{ |i| break i if min[i] != max[i] }
    min[0...idx]
  end

  def format_number(number, aggregate = 'count')
    f_amt = aggregate == 'count' ? number.round.to_s : ("%.2f" % number)
    i = f_amt.index(".") || f_amt.length
    while i > 3
      f_amt[i - 3] = " " + f_amt[i-3]
      i = f_amt.index(" ")
    end
    f_amt
  end
end
