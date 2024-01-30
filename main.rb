# frozen_string_literal: true
require 'bundler/setup'
require 'stringio'
require 'optparse'
require 'open-uri'
require 'yaml'

require 'byebug'
require 'capybara/dsl'
require 'loofah'
require 'gepub'
require 'mini_magick'

class MagicStoryCompiler
  include Capybara::DSL

  Capybara.default_driver = :selenium_chrome
  
  def make_book(set:, output_file:)
    if set.class == String
      set_name = set
    else
      set_name = set["name"]
    end
    articles = get_all_set_story_articles(set_name: set_name)

    book = GEPUB::Book.new

    book.add_title("Magic: The Gathering - #{set_name}")
    articles.map { |a| a[:author ]}.uniq.each { |author| book.add_creator(author) }

    images = {}

    book.ordered do
      articles.each do |article|
        article_body = Nokogiri::HTML.fragment(article[:text])
        image_tags = article_body.css("img")

        image_tags.each do |img|
          f = URI.open(img["src"])
          path = "image/#{img['src'].split('/').last}"
          images[path] = f
          img["src"] = "../#{path}"
        end

        builder = Nokogiri::HTML::Builder.with(Nokogiri::HTML5::Document.new) do |doc|
          doc.html do
            doc.head do
              doc.title(article[:title])
            end
            doc.body do
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
    images.each do |path, f|
      book.add_item(path, content: f)
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
    set_image = MiniMagick::Image.open(set["image_url"])
    set_image.resize('1600x2560')
    set_image.format('.jpeg')
    tf = Tempfile.new
    set_image.write(tf.path)
    book.add_item('image/cover.jpeg', content: tf).cover_image

    book.generate_epub(output_file)
  end

  def get_all_set_story_articles(set_name:)
    visit("https://magic.wizards.com/en/story")

    links = get_article_links(set_name: set_name)
    links.map do |link|
      get_story_article(story_hash: link)
    end
  end

  def get_story_article(story_hash:)
    visit(story_hash[:url])

    title = story_hash[:title].split("|").last.strip
    main_article = find("article")
    header = main_article.find("header")
    body = main_article.find("div.article-body")

    publish_date = header.find("time").text

    author = header.all("a").find { |e| e.text != 'Magic Story' }.text

    body_text = body['innerHTML']

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
    find_set_element(set_name: set_name).click

    find_story_switch_buttons.flat_map do |b|
      b.click
      find_article_elements.map do |el|
        title = el.find('h3').text(:all)
        link = el.find('a[aria-label="Read More"]')

        {
          title: title,
          url: link['href']
        }
      end
    end
  end

  def find_story_switch_buttons()
    main_story_button = find_story_archive.find_button("Magic Story")
    begin
      side_story_button = find_story_archive.find_button("Side Stories")
    rescue Capybara::ElementNotFound
    end
    [
      main_story_button,
      side_story_button
    ].compact
  end
  
  def find_article_elements
    find_story_archive.all('article')
  end
  
  def find_set_element(set_name:)
    sets = find_set_slider
    years = find_year_slider

    years.all("span.swiper-slide").each do |y|
      y.click
      begin
        set = sets.find("div.swiper-slide", text: set_name) 
      rescue Capybara::ElementNotFound
        next
      end
      return set if set
    end
  end

  def find_year_slider()
    scroll_to(find_story_archive)
    has_selector?("section#story-arcive div.swiper-wrapper")     
    sliders = all("section#story-archive div.swiper-wrapper")
  
    sliders.find { |s| s.all("span", text: 2023).length > 0 }
  end

  def find_set_slider()
    scroll_to(find_story_archive)
    has_selector?("section#story-arcive div.swiper-wrapper")     
    sliders = all("section#story-archive div.swiper-wrapper")

    sliders.reject { |s| s.all("span", text: 2023).length > 0 }.first
  end

  def find_story_archive
    find("section#story-archive")
  end
end

parser = OptionParser.new
parser.on('-f', '--file [FILENAME]', 'A YAML file containing all the sets to create books for')
parser.on('-n', '--set-name [SETNAME]', 'Set name to create a book for')
parser.on('-o', '--output-folder [OUTPUT]', 'The folder to output the finished book to. Defaults to the current folder')

options = {
  :"output-folder" => "./"
}

parser.parse!(into: options)

if options.keys.include?(:file) && options.keys.include?(:"set-name")
  fail "Supply either a file of set names, or a single set, but not both"
end

sets = if options.keys.include?(:"set-name")
         [options[:"set-name"]]
       elsif options.keys.include?(:file)
        YAML.load(File.read(options[:file]))
       end || []

compiler = MagicStoryCompiler.new

sets.each do |set|
  set_name = if set.class == String
               set
             else
               set["name"]
             end

  book_name = "Magic: The Gathering - #{set_name}.epub"
  output_folder = File.expand_path(options[:"output-folder"], File.dirname(__FILE__))
  compiler.make_book(set: set, output_file: File.join(output_folder, book_name))
end