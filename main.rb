# frozen_string_literal: true
require 'bundler/setup'
require 'stringio'
require 'optparse'
require 'open-uri'

require 'byebug'
require 'capybara/dsl'
require 'loofah'
require 'gepub'

class MagicStoryCompiler
  include Capybara::DSL

  Capybara.default_driver = :selenium_chrome
  
  def make_book(set_name:, output_file:)
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
          path = "../image/#{img['src'].split('/').last}"
          images[path] = f
          img["src"] = path
        end

        builder = Nokogiri::HTML::Builder.new do |doc|
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
        # use nokogiri::builder and download images
        book.add_item("text/#{article[:title].gsub(':', '').gsub(' ', '_').downcase}.xhtml").
             add_content(StringIO.new(builder.to_html)).
             toc_text(article[:title]).
             landmark(type: 'bodymatter', title: article[:title])
      end
    end
    images.each do |path, f|
      book.add_item(path, content: f)
    end

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
parser.on('-f', '--file [FILENAME]', 'A file containing all the sets to create books for, one set per line')
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
        File.readlines(options[:file], chomp: true)
       end || []

compiler = MagicStoryCompiler.new

sets.each do |set_name|
  book_name = "Magic: The Gathering - #{set_name}.epub"
  output_folder = File.expand_path(options[:"output-folder"], File.dirname(__FILE__))
  compiler.make_book(set_name: set_name, output_file: File.join(output_folder, book_name))
end