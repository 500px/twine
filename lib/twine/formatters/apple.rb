require 'Nokogiri'

module Twine
  module Formatters
    class Apple < Abstract
      def format_name
        'apple'
      end

      def extension
        '.strings'
      end

      def can_handle_directory?(path)
        Dir.entries(path).any? { |item| /^.+\.lproj$/.match(item) }
      end

      def can_handle_file?(path)
        return File.extname(path) == ".strings" || File.extname(path) == ".stringsdict"
      end

      def default_file_name
        return 'Localizable.strings'
      end

      def default_plural_file_name
        return 'Localizable.stringsdict'
      end

      def determine_language_given_path(path)
        path_arr = path.split(File::SEPARATOR)
        path_arr.each do |segment|
          match = /^(.+)\.lproj$/.match(segment)
          if match
            if match[1] != "Base"
              return match[1]
            else
              return 'en'
            end
          end
        end

        return
      end

       def output_path_for_language(lang)
        "#{lang}.lproj"
      end

      def read(io, lang)
        uncategorized_section = nil
        if !section_exists('Uncategorized')
          uncategorized_section = TwineSection.new('Uncategorized')
          @twine_file.sections.insert(0, uncategorized_section)
        else
          uncategorized_section = get_section('Uncategorized')
        end
        last_comment = nil
        while line = io.gets
          # matches a `key = "value"` line, where key may be quoted or unquoted. The former may also contain escaped characters
          match = /^\s*((?:"(?:[^"\\]|\\.)+")|(?:[^"\s=]+))\s*=\s*"((?:[^"\\]|\\.)*)"/.match(line)
          if match
            key = match[1]
            key = key[1..-2] if key[0] == '"' and key[-1] == '"'
            key.gsub!('\\"', '"')
            value = match[2]
            value.gsub!('\\"', '"')
            value.gsub!('%s', '%@')
            value.gsub!('$s', '$@')
            set_translation_for_key(uncategorized_section, key, lang, value)
            if last_comment
              set_comment_for_key(key, last_comment)
            end
          end

          match = /\/\* (.*) \*\//.match(line)
          if match
            last_comment = match[1]
          else
            last_comment = nil
          end
        end

        # Handle plural files
        if (!File.file?(plural_input_file_for_lang(lang)))
          return
        end

        doc = File.open(plural_input_file_for_lang(lang)) { |f| Nokogiri::XML(f) }
        comment = nil
        key = nil
        value = nil

        top_level_dict = doc.css("dict").first
        whole_dicts = top_level_dict.xpath("./dict")
        plural_keys = top_level_dict.xpath("./key")

        for i in 0 ... whole_dicts.size do
          current_dict = whole_dicts[i]
          comment = current_dict.css("string").first.content
          key = plural_keys[i].content.to_s

          nested_dict = current_dict.xpath("./dict")
          nested_dict_keys = nested_dict.xpath("./key")
          nested_dict_strings = nested_dict.xpath("./string")

          section = nil
          if !section_exists(key)
            section = TwineSection.new(key)
            @twine_file.sections.insert(@twine_file.sections.size - 1, section)
          else
            section = get_section(key)
          end

          for j in 0 ... nested_dict_keys.children.size do
            cur_xml_key = nested_dict_keys.children[j]
            if !cur_xml_key.content.include? "NSString"
              modified_key = key + "__" + cur_xml_key.content.to_s

              set_translation_for_key(section, modified_key, lang, nested_dict_strings[j].content.to_s)
              set_ios_comment_for_key(modified_key, comment)
            end
          end
        end
      end

      def plural_input_file_for_lang(lang)
        path = @options[:input_path]
        if path.include?(output_path_for_language(lang))
          if File.extname(path) == ".strings"
            filename = File.basename(path,".*")
            path.sub(filename + ".strings", filename + ".stringsdict")
          else
            path + "/" + default_plural_file_name
          end
        else
          path + output_path_for_language(lang) + "/" + default_plural_file_name
        end
      end

      def plural_output_file_for_lang(lang)
        path = @options[:output_path]
        if path.include?(output_path_for_language(lang))
          if File.extname(path) == ".strings"
            filename = File.basename(path,".*")
            path.sub(filename + ".strings", filename + ".stringsdict")
          else
            path + "/" + default_plural_file_name
          end
        else
          path + output_path_for_language(lang) + "/" + default_plural_file_name
        end
      end

      def should_include_definition(definition, lang)
        return super(definition, lang) && !definition.translation_for_lang(lang).include?("`")
      end

      def format_sections(twine_file, lang)
        out_file = File.open(plural_output_file_for_lang(lang), "w")
        out_file.puts(format_header_stringsdict)

        sections = Array.new(twine_file.sections.size)
        for i in 0 ... twine_file.sections.size
          section = twine_file.sections[i]
          if section.is_uncategorized
            sections[i] = format_section(section, lang)
          else
            format_section_plural(section, lang, out_file)
          end
        end
        out_file.puts(format_footer_stringsdict)
        out_file.close
        sections.compact.join("\n")
      end

      def format_section(section, lang)
        definitions = section.definitions.select { |definition| should_include_definition(definition, lang) }
        return if definitions.empty?

        result = ""

        if section.name && section.name.length > 0
          section_header = format_section_header(section)
          result += "\n#{section_header}" if section_header

          if section.is_uncategorized
            definitions.map! { |definition| format_definition(definition, lang) }
            definitions.compact! # remove nil definitions
            definitions.map! { |definition| "\n#{definition}" }  # prepend newline
            result += definitions.join
          end
        end
      end

      def format_section_plural(section, lang, out_file)
        plural_key = section.name
        main_file_contains_key = main_localizable_file_contains_key(plural_key)

        for i in 0 ... section.definitions.size
          definition = section.definitions[i]
          value = definition.translation_for_lang_or_nil(lang, @twine_file.language_codes[0])
          ios_localized_format_key = definition.ios_comment

          if ios_localized_format_key == nil
            puts "[" + plural_key + "]"

            if main_file_contains_key
              puts "Needs matching key in Localizable.strings"
            else
              puts  "This is an Android-only plural"
            end
            return
          end

          if i == 0 && main_file_contains_key
            out_file.puts(format_plural_start(plural_key, ios_localized_format_key.to_s))
          end

          if value != nil && main_file_contains_key
            out_file.puts(format_plural_key_value(definition.key, format_value_plural(value.dup)))
          end
        end

        if main_file_contains_key
          out_file.puts(format_plural_section_end)
        end
      end

      def main_localizable_file_contains_key(key)
        @twine_file.sections.each do |section|
          if section.is_uncategorized
            section.definitions.each do |definition|
              if definition.key == key
                return true
              end
            end
            return false
          end
        end
        # Should never reach here
        return false
      end

      ########### PLURALS START ###########

      def format_header_stringsdict
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
        "<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n" +
        "<plist version=\"1.0\">\n" +
        "    <dict>\n"
      end

      def format_plural_start(section_name, comment)
        comment_parts = comment.split("@")

        # TODO: Should this be hardcoded or using Nokogiri somehow?
        "        <key>#{section_name}</key>\n" +
        "        <dict>\n" +
        "            <key>NSStringLocalizedFormatKey</key>\n" +
        "            <string>#{comment}</string>\n" +
        "            <key>#{comment_parts[1]}</key>\n" +
        "            <dict>\n" +
        "                <key>NSStringFormatSpecTypeKey</key>\n" +
        "                <string>NSStringPluralRuleType</string>\n" +
        "                <key>NSStringFormatValueTypeKey</key>\n" +
        "                <string>d</string>\n"
      end

      def format_plural_key_value(plural_key, plural_string)
        plural_key_parts = plural_key.rpartition(/.__/)
        # TODO: Nokogiri?
        "                <key>#{plural_key_parts[plural_key_parts.length - 1]}</key>\n" +
        "                <string>#{plural_string}</string>\n"
      end

      def format_plural_section_end
        # TODO: Nokogiri?
        "            </dict>\n" +
        "        </dict>\n"
      end

      def format_footer_stringsdict
        # TODO: Nokogiri?
        "    </dict>\n" +
        "</plist>"
      end

      ########### PLURALS END ###########

      def format_header(lang)
        "/**\n * Apple Strings File\n * Generated by Twine #{Twine::VERSION}\n * Language: #{lang}\n */"
      end

      def format_section_header(section)
        "/********** #{section.name} **********/\n"
      end

      def key_value_pattern
        "\"%{key}\" = \"%{value}\";\n"
      end

      def format_comment(definition, lang)
        "/* #{definition.comment.gsub('*/', '* /')} */\n" if definition.comment
      end

      def format_key(key)
        escape_quotes(key)
      end

      def format_value(value)
        text = escape_quotes(value)
        text.gsub("b>", "strong>")
      end

      def format_value_plural(value)
        text = escape_quotes(value)
        text.gsub("b>", "strong&gt;").gsub("<", "&lt;")
      end
    end
  end
end

Twine::Formatters.formatters << Twine::Formatters::Apple.new
