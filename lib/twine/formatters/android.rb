# encoding: utf-8
require 'cgi'
require 'rexml/document'
require 'Nokogiri'

module Twine
  module Formatters
    class Android < Abstract
      include Twine::Placeholders

      LANG_MAPPINGS = Hash[
        'zh-rCN' => 'zh-Hans',
        'zh-rHK' => 'zh-Hant',
        'en-rGB' => 'en-UK',
        'in' => 'id',
        'nb' => 'no'
        # TODO: spanish
      ]

      def format_name
        'android'
      end

      def extension
        '.xml'
      end

      def can_handle_directory?(path)
        Dir.entries(path).any? { |item| /^values.*$/.match(item) }
      end

      def can_handle_file?(path)
        return File.extname(path) == ".xml"
        #path_arr = path.split(File::SEPARATOR)
        #return path_arr[path_arr.length - 1] == default_file_name
      end

      #def default_file_name
      #  return 'strings.xml'
      #end

      def determine_language_given_path(path)
        path_arr = path.split(File::SEPARATOR)
        path_arr.each do |segment|
          if segment == 'values'
            return 'en'
          else
            # The language is defined by a two-letter ISO 639-1 language code, optionally followed by a two letter ISO 3166-1-alpha-2 region code (preceded by lowercase "r").
            # see http://developer.android.com/guide/topics/resources/providing-resources.html#AlternativeResources
            match = /^values-([a-z]{2}(-r[a-z]{2})?)$/i.match(segment)
            if match
              lang = match[1]
              lang = LANG_MAPPINGS.fetch(lang, lang)
              lang.sub!('-r', '-')
              return lang
            end
          end
        end

        return
      end

      def output_path_for_language(lang)
        if lang == 'en'
          "values"
        else
          "values-" + (LANG_MAPPINGS.key(lang) || lang)
        end
      end

      def set_translation_for_key(section, key, lang, value)
        value = CGI.unescapeHTML(value)
        value.gsub!('\\\'', '\'')
        value.gsub!('\\"', '"')
        value = convert_placeholders_from_android_to_twine(value)
        value.gsub!('\@', '@')
        value.gsub!(/(\\u0020)*|(\\u0020)*\z/) { |spaces| ' ' * (spaces.length / 6) }
        super(section, key, lang, value)
      end

      def cdata_start
        "<![CDATA["
      end

      def cdata_end
        "]]>"
      end

      # This is true if the child's text contains: <a href="/item"></a> OR <![CDATA[]]>
      def does_text_have_html_styling?(child)
        xml_content =  Nokogiri::XML(child).first_element_child

        # If the content of the xml element has an element within it, let's
        # give it double quotes and keep the string verbatim
        !xml_content.first_element_child.nil? || html_styling_with_cdata?(child)
      end

      def html_styling_with_cdata?(child)
        child.include?(cdata_start)
      end

      def read(io, lang)
        document = REXML::Document.new io, :compress_whitespace => %w{ string }

        comment = nil
        document.root.children.each do |child|
          if child.is_a? REXML::Comment
            content = child.string.strip
            comment = content if content.length > 0 and not content.start_with?("SECTION:")

          elsif child.is_a? REXML::Element

            if child.attributes['translatable']
              next
            end

            section = nil
            if child.name == 'plurals'
              key = child.attributes['name']

              if !section_exists(key)
                section = TwineSection.new(key)
                @twine_file.sections.insert(@twine_file.sections.size - 1, section)
              else
                section = get_section(key)
              end

              child.each do |item|
                if item.is_a? REXML::Element
                  plural_key = key + '__' + item.attributes['quantity']

                  handle_translation_for_key(section, plural_key, lang, item)
                end
              end
            elsif child.name == 'string'

              if !section_exists('Uncategorized')
                section = TwineSection.new('Uncategorized')
                @twine_file.sections.insert(0, section)
              else
                section = get_section('Uncategorized')
              end

              key = child.attributes['name']

              handle_translation_for_key(section, key, lang, child)
              set_comment_for_key(key, comment) if comment

              comment = nil
            end
          end
        end
      end

      def handle_translation_for_key(section, key, lang, child)
        child_string = child.to_s
        translation_value = nil
        if does_text_have_html_styling?(child_string)
          translation_value = get_translation_for_html_styled_value(child_string)
        else
          translation_value = child.text
        end

        set_translation_for_key(section, key, lang, translation_value)
      end

      # Add double quotes `` to html-styled strings so they will be read/written verbatim
      def get_translation_for_html_styled_value(child_string)
        xml_content =  Nokogiri::XML(child_string).first_element_child

        if html_styling_with_cdata?(child_string)
          index_start = child_string.index(cdata_start)
          index_end = child_string.index(cdata_end) + cdata_end.length - 1
          return "`" + child_string[index_start..index_end] + "`"
        else
          return "`" + xml_content.inner_html.to_s + "`"
        end
      end

      def format_header(lang)
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<!-- Android Strings File -->\n<!-- Generated by Twine #{Twine::VERSION} -->\n<!-- Language: #{lang} -->"
      end

      def format_sections(twine_file, lang)
        if @options[:output_path].include? "donottranslate"
          result = '<resources xmlns:tools="http://schemas.android.com/tools" tools:ignore="MissingTranslation">'
        else 
          result = '<resources>'
        end

        result += super + "\n"

        result += "</resources>\n"
      end

      def format_section(section, lang)
        definitions = section.definitions.select { |definition| should_include_definition(definition, lang) }
        return if definitions.empty?

        result = ""

        if section.name && section.name.length > 0
          section_header = format_section_header(section)
          result += "\n#{section_header}" if section_header

          # DEAL WITH PLURALS HERE
          if section.is_uncategorized
            definitions.map! do |definition|
              # Only output definitions that are in the correct language
              if definition.translation_for_lang_or_nil(lang, @options[:developer_language] || @twine_file.language_codes[0])
                format_definition(definition, lang)
              end
            end
            definitions.compact! # remove nil definitions
            definitions.map! { |definition| "\n#{definition}" }  # prepend newline
            result += definitions.join
          else
            # If the plural section has no definitions in this language, skip it
            # Otherwise, only output the correct definitions of the correct language
            definitions.delete_if { |definition| definition.translation_for_lang_or_nil(lang, @twine_file.language_codes[0]).nil? }

            if !definitions.empty?
              result +=  plurals_start_key_value_pattern % { key:section.name }
              definitions.map! { |definition| format_plural(definition, lang) }
              definitions.compact! # remove nil definitions
              definitions.map! { |definition| "\n#{definition}" }  # prepend newline
              result += definitions.join
              result += plurals_end_key_value_pattern
            end
          end
        end
      end

      def format_section_header(section)
        "    <!-- SECTION: #{section.name} -->"
      end

      def format_comment(definition, lang)
        "    <!-- #{definition.comment.gsub('--', '—')} -->\n" if definition.comment
      end

      def key_value_pattern
        "    <string name=\"%{key}\">%{value}</string>"
      end

      def format_plural(definition, lang)
        [format_comment(definition, lang), format_key_value_plural_item(definition, lang)].compact.join
      end

      def format_key_value_plural_item(definition, lang)
        value = definition.translation_for_lang(lang)
        plurals_item_key_value_pattern(format_key(definition.key.dup), format_value(value.dup))
      end

      def plurals_start_key_value_pattern
        "\n    <plurals name=\"%{key}\">"
      end

      def plurals_item_key_value_pattern(key, value)
        partitions = key.rpartition(/.__/)
        "        <item quantity=\"" + partitions[partitions.length - 1] + "\">" + value + "</item>"
      end

      def plurals_end_key_value_pattern
        "\n    </plurals>"
      end

      def escape_value(value)
        # escape double and single quotes, & signs and tags
        value = escape_quotes(value)
        value.gsub!("'", "\\\\'")
        value.gsub!(/&/, '&amp;')
        value.gsub!('<', '&lt;')

        # escape non resource identifier @ signs (http://developer.android.com/guide/topics/resources/accessing-resources.html#ResourcesFromXml)
        resource_identifier_regex = /@(?!([a-z\.]+:)?[a-z+]+\/[a-zA-Z_]+)/   # @[<package_name>:]<resource_type>/<resource_name>
        value.gsub(resource_identifier_regex, '\@')

        value.gsub('strong>', 'b>')
      end

      # see http://developer.android.com/guide/topics/resources/string-resource.html#FormattingAndStyling
      # however unescaped HTML markup like in "Welcome to <b>Android</b>!" is stripped when retrieved with getString() (http://stackoverflow.com/questions/9891996/)
      def format_value(value)
        value = value.dup

        # If there are double quotes, we want to return the string verbatim
        # Definition scrubs the double quotes to single in twine_file.rb line 178
        if value.include? "`"
          value = value[1..-2] if value[0] == '`' && value[-1] == '`'
          return value
        end

        # capture xliff tags and replace them with a placeholder
        xliff_tags = []
        value.gsub! /<xliff:g.+?<\/xliff:g>/ do
          xliff_tags << $&
          'TWINE_XLIFF_TAG_PLACEHOLDER'
        end

        # escape everything outside xliff tags
        value = escape_value(value)

        # put xliff tags back into place
        xliff_tags.each do |xliff_tag|
          # escape content of xliff tags
          xliff_tag.gsub! /(<xliff:g.*?>)(.*)(<\/xliff:g>)/ do "#{$1}#{escape_value($2)}#{$3}" end
          value.sub! 'TWINE_XLIFF_TAG_PLACEHOLDER', xliff_tag
        end

        # convert placeholders (e.g. %@ -> %s)
        value = convert_placeholders_from_twine_to_android(value)

        # replace beginning and end spaces with \u0020. Otherwise Android strips them.
        value.gsub(/\A *| *\z/) { |spaces| '\u0020' * spaces.length }
        value.gsub('%#s', '%#@')
      end

    end
  end
end

Twine::Formatters.formatters << Twine::Formatters::Android.new
