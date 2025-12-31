# frozen_string_literal: true
require 'bundler/setup'
require 'stringio'
require 'optparse'
require 'open-uri'
require 'yaml'
require 'fileutils'
require 'active_support'
require 'active_support/inflector'
require 'active_support/core_ext'
require 'byebug'
require 'capybara/dsl'
require 'loofah'
require 'gepub'
require 'mini_magick'
require 'date'
require 'faraday'
require 'zip'
require 'faraday/retry'

class MagicStoryCompiler
  include Capybara::DSL

  Capybara.default_driver = :selenium_chrome
  
  def make_book(set_code:, output_folder:)
    set = set_data(set_code:)
    articles = get_all_set_story_articles(set: set)
    book_name = "Magic: The Gathering - #{set[:name]}.epub"
    output_epub_file = File.join(output_folder, book_name)

     unless story_text_changed?(set_code:, articles:, output_folder:)
       epub_folder = File.join(output_folder, "epub")
       filename = File.join(epub_folder, File.basename(output_epub_file))
       return { filename: filename, existing_file: true }
     end

     digest_file_name = digest_file_name(output_folder:, set_code:)
     FileUtils.mkdir_p(File.dirname(digest_file_name))
     File.write(digest_file_name, story_text_hash(articles:))
    
    book = GEPUB::Book.new

    book.add_title("Magic: The Gathering - #{set[:name]}")
    book.add_item("assets/base.css", content: File.open(File.expand_path("./ebook-css/css/base.css", File.dirname(__FILE__))))
    book.add_item("assets/overrides.css", content: File.open(File.expand_path("./overrides.css", File.dirname(__FILE__))))
    articles.map { |a| a[:author ]}.uniq.each { |author| book.add_creator(author) }

    publish_date = articles.map { |a| Date.parse(a[:publish_date]) }.max
    book.add_date(publish_date.to_time)

    book.ordered do
      copyright_page = Nokogiri::HTML::Builder.with(Nokogiri::HTML5::Document.new) do |doc|
        doc.html do
          doc.head do
            doc.title("Copyright")
            doc.link(rel: "stylesheet", href: "../assets/base.css")
            doc.link(rel: "stylesheet", href: "../assets/overrides.css")
          end
          doc.body do
            doc.div do
              doc.text("This book is unofficial Fan Content permitted under the Fan Content Policy. Not approved/endorsed by Wizards.")
              doc.br
              doc.text("All text, images, and other portions of the materials used are property of Wizards of the Coast.")
              doc.br
              doc.text("©Wizards of the Coast LLC.")
            end
          end
        end
      end.to_html
      book.add_item('text/copyright.html', content: StringIO.new(copyright_page))
      articles.each do |article|
        article_body = Nokogiri::HTML.fragment(article[:text])

        builder = Nokogiri::HTML::Builder.with(Nokogiri::HTML5::Document.new) do |doc|
          doc.html do
            doc.head do
              doc.title(article[:title])
              doc.link(rel: "stylesheet", href: "../assets/base.css")
              doc.link(rel: "stylesheet", href: "../assets/overrides.css")
            end
            doc.body(class: "story") do
              doc.h1(article[:title])
              doc << article_body
            end
          end
        end

        book.add_item("text/#{article[:title].gsub(':', '').gsub(' ', '_').downcase}.html").
             add_content(StringIO.new(builder.to_html)).
             toc_text(article[:title]).
             landmark(type: 'bodymatter', title: article[:title])
      end
    end

# going to use this to create a cover and then add another image on top 
#magick -background black -fill white -size 1600x2560 -pointsize 64 -gravity north caption:"Magic: The Gathering - Wilds of Eldraine" 
#-splice 0x200 -gravity south -chop 0x200  cover.jpeg
    # tf = Tempfile.new(['cover', '.jpeg'])
    # MiniMagick::Tool::Magick.new do |magick|
    #   magick.background('black')
    #   magick.fill('white')
    #   magick.size('1600x2560')
    #   magick.pointsize('64')
    #   magick.gravity('north')
    #   magick << "caption:Magic: The Gathering\n#{set_name}"
    #   # magick.caption("Magic: The Gathering #{set_name}")
    #   magick.splice('0x200')
    #   magick.gravity('south')
    #   magick.chop('0x200')
    #   magick << tf.path
    # end

    # cover = MiniMagick::Image.open(tf.path)
    # set_image = MiniMagick::Image.open(set["image_url"]) 
    # set_image.resize('1600x')
    # set_image.format('.jpeg')

    # result = cover.composite(set_image) do |c|
    #   c.compose("Over")
    #   c.gravity("southeast")
    #   c.geometry("+0+200")
    #   c.colorspace('sRGB')
    # end

    # output_tf = Tempfile.new(['cover_final', '.jpeg'])
    # result.write(output_tf.path)

    # book.add_item('image/cover.jpeg', content: output_tf).cover_image
    set_image = MiniMagick::Image.open(set[:image_url])
    set_image.resize('1600x2560')
    set_image.format('.jpeg')
    tf = Tempfile.new
    set_image.write(tf.path)
    book.add_item('image/cover.jpeg', content: tf).cover_image

    book.generate_epub(output_epub_file)
    { filename: output_epub_file, existing_file: false }
  end

  def get_all_set_story_articles(set:)
    visit("https://magic.wizards.com/en/story")

    links = set["article_links"]&.map { |h| h.transform_keys(&:to_sym) } || get_article_links(set_name: set[:name])
    links.map do |link|
      get_story_article(story_hash: link)
    end
  end

  def get_story_article(story_hash:)
    puts "visiting #{story_hash[:url]}"
    visit(story_hash[:url])

    category = story_hash[:category] == 'Magic Story' ? "" : "#{story_hash[:category]}: "
    title = "#{category}#{story_hash[:title].split("|").last.strip}"
    header = find("header")
    body = find("div.article-body")
    publish_date = header.find("time").text

    author = header.all("a").find { |e| e.text != 'Magic Story' }&.text || ""

    body_text = body['innerHTML']

    # for some reason the wizards CMS thinks nbsp is a tag and not an entity, and this
    # tag is thenremoved by the loofah scrubber
    body_text.gsub!(/<nbsp>\. \. \.<\/nbsp>/, "&nbsp;...&nbsp;")

    # after we scrub out any unsafe tags, there can be empty paragraphs or horizontal rules with nothing above them
    # and this scrubber will remove them
    empty_scrubber = Loofah::Scrubber.new do |node|
      if node.name == 'p'  && node.text.strip == ""
        node.remove
      elsif node.name == 'text' && node.text.strip == "" && node.previous.nil?
        node.remove
      elsif node.name == 'hr' && node.previous.nil?
        node.remove
      end
      Loofah::Scrubber::STOP
    end

    clean_body_text = Loofah.html5_fragment(body_text).scrub!(:prune).scrub!(empty_scrubber).to_s

    story_hash.merge(author: author, publish_date: publish_date, text: clean_body_text, title: title)
  end

  def get_article_links(set_name:)
    set_element = find_set_element(set_name: set_name)
    scroll_to(set_element)
    set_element.click

    find_story_switch_buttons.flat_map do |b|
      scroll_to(b)
      b.click
      find_article_elements.map do |el|
        title = el.find('h3').text(:all)
        link = el.find('a[aria-label="Read More"]')

        {
          category: b.text.titleize,
          title: title,
          url: link['href']
        }
      end
    end
  end

  def set_data(set_code:)
    conn = Faraday.new("https://api.scryfall.com") do |builder|
      builder.response :json
    end
    res = conn.get("/sets/#{set_code}")
    release_year = res.body["released_at"].split("-").first
    name = res.body["name"]
    pdf_url = try_marketing_url_years(
      url: "https://media.wizards.com/%{year}/wpn/marketing_materials/%{set_code_path}/%{set_code_file}_lgp_key_24x36_EN.pdf", 
      set_code: set_code
    )

    image_url = unless pdf_url.blank?
      pdf_url
    else
      zip_url = try_marketing_url_years(
        url: "https://media.wizards.com/%{year}/wpn/marketing_materials/%{set_code_path}/%{set_code_file}_sma_key_en.zip", 
        set_code: set_code
      )
      image_file = Tempfile.create
      image_file.binmode
      Tempfile.create do |f|
        f.binmode
        res = Faraday.get(zip_url)
        f.write(res.body)
        Zip::File.open(f.path) do |zip_file|
          entry = zip_file.entries.find { |e| e.name.match?(/1080x1350/)}
        
          image_file.write(entry.get_input_stream.read)
        end
      end
      image_file.path
    end

    {
      code: set_code,
      name: name,
      image_url: image_url
    }
  end

  def story_text_hash(articles:)
    all_article_text = articles.map { |a| a[:text] }.join("\n")
    OpenSSL::Digest.hexdigest("SHA256", all_article_text)
  end

  def story_text_changed?(set_code:, articles:, output_folder:)
    digest_file_name = digest_file_name(output_folder:, set_code:)

    return true unless File.exist?(digest_file_name)

    existing_digest = File.read(digest_file_name)
    story_text_hash = story_text_hash(articles:)
    existing_digest != story_text_hash
  end

  def digest_file_name(output_folder:, set_code:)
    digest_folder = File.join(output_folder, "digests")
    FileUtils.mkdir_p(digest_folder)
    digest_file_name = File.join(digest_folder, set_code)
  end

  def try_marketing_url_years(url:, set_code:)
    unless url.match?(/%{year}/)
      raise ArgumentError "URL must contain the replacement string '%{year}'"
    end
    params = [
      { set_code_path: set_code.downcase, set_code_file: set_code.downcase },
      { set_code_path: set_code.upcase, set_code_file: set_code.downcase },
      { set_code_path: set_code.downcase, set_code_file: set_code.upcase },
      { set_code_path: set_code.upcase, set_code_file: set_code.upcase },
    ]
    current_year = Date.today.year
    years = (2017..current_year).to_a.reverse
    retry_options = {
      max: 4,
      interval: 0.05,
      interval_randomness: 0.5,
      backoff_factor: 2,
      retry_statuses: [404]
    }
    connection = Faraday.new do |f|
      f.request :retry, retry_options
    end
    params.each do |p|
      years.each do |year|
        year_url = url % p.merge({ year: year })
        res = connection.head(year_url)
        return year_url unless res.status == 404
      end
    end

    return nil
  end

  def find_story_switch_buttons()
    main_story_button = find_story_archive.find_button("Magic Story", disabled: :all, visible: false)
    begin
      side_story_button = find_story_archive.find_button("Side Stories", disabled: :all, visible: false)
      # only in Neon Dynasty i think
      saga_story_button = find_story_archive.find_button("Saga Stories", disabled: :all, visible: false)
    rescue Capybara::ElementNotFound
    end
    [
      main_story_button,
      side_story_button,
      saga_story_button
    ].compact
  end
  
  def find_article_elements
    find_story_archive.all('article')
  end
  
  def find_set_element(set_name:)
    sets = find_set_slider
    years = find_year_slider
    years.all("span.swiper-slide", visible: false).each do |y|
      y.click
      begin
        set = sets.find("div.swiper-slide", text: /#{set_name}/, visible: false) 
      rescue Capybara::ElementNotFound
        next
      end
      return set if set
    end
  end

  def find_year_slider()
    scroll_to(find_story_archive)
    has_selector?("section#arcive div.swiper-wrapper")     
    sliders = all("section#archive div.swiper-wrapper")
  
    sliders.find { |s| s.all("span", text: 2023).length > 0 }
  end

  def find_set_slider()
    scroll_to(find_story_archive)
    has_selector?("section#arcive div.swiper-wrapper")     
    sliders = all("section#archive div.swiper-wrapper")

    sliders.reject { |s| s.all("span", text: 2023).length > 0 }.first
  end

  def find_story_archive
    find("section#archive")
  end
end

parser = OptionParser.new
parser.on('-f', '--file [FILENAME]', 'A YAML file containing all the sets to create books for')
parser.on('-n', '--set-name [SETNAME]', 'Set name to create a book for')
parser.on('-o', '--output-folder [OUTPUT]', 'The folder to output the finished book to. Defaults to the current folder')
parser.on('-i', '--cover-image-url [IMAGE]', 'A cover image to add to the book')
parser.on('--formats [FORMATS]', 'Formats to output books in, defaults to epub,pdf,mobi,kfx. Input should be comma separated formats. Available formats are epub, pdf, mobi, kfx, azw3')

options = {
  :"output-folder" => "./",
  formats: "epub,pdf,mobi,kfx"
}

parser.parse!(into: options)

non_file_required_options = %i["set-name" "cover-image-url"]

# check to see if --file was passed, then you shouldn't have --set-name and --cover-image-url. intersecting the arrays should show both options still, if any are nissing then fail
if options.keys.include?(:file)
  if (non_file_required_options - options.keys).length < 2
    fail "Supply either a file of set names, or a name and image arguments for a single set, but not both"
  end
elsif (non_file_required_options - options.keys).empty?
  fail "Must supply both a set name and a cover image url"
end

sets = if options.keys.include?(:"set-name")
         [{"name" => options[:"set-name"], "image_url" => options[:"cover-image-url"]}]
       elsif options.keys.include?(:file)
        YAML.load(File.read(options[:file]))
       end || []

formats = options[:formats].split(',')
compiler = MagicStoryCompiler.new

sets.each do |set|
  pp set
  output_folder = File.expand_path(options[:"output-folder"])
  FileUtils.mkdir_p(output_folder)
  
  output = compiler.make_book(set_code: set, output_folder: output_folder)
  output_epub_file = output[:filename]
  calibre_tools_path = "/Applications/calibre.app/Contents/MacOS"

  # skip polishing commands if we are using a pre-existing file
  unless output[:existing_file]
    # polish the book to embed all the images, remove unused css and update punctuation
    polish_command = [
      "#{calibre_tools_path}/ebook-polish", 
      "--download-external-resources",
      "--remove-unused-css",
      "--smarten-punctuation",
      "--embed-fonts",
      "--verbose",
      "\"#{output_epub_file}\"",
      "\"#{output_epub_file}\""
    ]

    Kernel.system(polish_command.join(' '))

    # compress the images after to also get the downloaded images
    compress_images_command = [
      "#{calibre_tools_path}/ebook-polish", 
      "--compress-images",
      "--verbose",
      "\"#{output_epub_file}\"",
      "\"#{output_epub_file}\""
    ]
    Kernel.system(compress_images_command.join(' '))
  end

  formats.each do |format|
    unless format == 'epub'
      format_folder = File.join(output_folder, format)
      FileUtils.mkdir_p(format_folder)
      output_file_name = "#{File.basename(output_epub_file, ".*")}.#{format}"
      convert_command = [
        "#{calibre_tools_path}/ebook-convert",
        "\"#{output_epub_file}\"",
        "\"#{File.join(format_folder, output_file_name)}\"",
        ('--output-profile tablet' if format == 'mobi')
      ]
      Kernel.system(convert_command.compact.join(' '))
    end
  end

  if formats.include?("epub") && !output[:existing_file]
    epub_folder = File.join(output_folder, "epub")
    FileUtils.mkdir_p(epub_folder)
    FileUtils.mv(output_epub_file, File.join(epub_folder, File.basename(output_epub_file)))
  end
end