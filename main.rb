# frozen_string_literal: true
require 'capybara/dsl'
require 'loofah';

class MagicStoryCompiler
  include Capybara::DSL

  Capybara.default_driver = :selenium_chrome

  def initialize()
    visit("https://magic.wizards.com/en/story")
  end

  def get_all_set_story_articles(set_name:)
    links = get_article_links(set_name: set_name)
    links.map do |link|
      get_story_article(story_hash: link)
    end
  end

  def get_story_article(story_hash:)
    visit(story_hash[:url])

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

    story_hash.merge(author: author, publish_date: publish_date, text: clean_body_text)
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