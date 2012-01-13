require 'pathname' #dosya yolunu yazarak metodu çalıstırmak.
require 'pythonconfig' #python programını yapılandırmak.
require 'yaml' #islemek istediğimiz verileri olusturan dosya.
CONFIG = Config.fetch('presentation', {}) #gerekli yapılandırmalar.

PRESENTATION_DIR = CONFIG.fetch('directory', 'p') #sunmak için gerekli olan dizin.
DEFAULT_CONFFILE = CONFIG.fetch('conffile', '_templates/presentation.cfg') #on tanımlı olarak ayar yapmak.
INDEX_FILE = File.join(PRESENTATION_DIR, 'index.html') #dosyada indeksleri olusturmak.
IMAGE_GEOMETRY = [ 733, 550 ] #resmin boyutları.
DEPEND_KEYS    = %w(source css js) # baglı olarak anahtarlama.
DEPEND_ALWAYS  = %w(media) #sürekli gelen bagımlılık.
TASKS = { #hedef gorevler ve tanımları.
    :index   => 'sunumları indeksle',
    :build   => 'sunumları oluştur',
    :clean   => 'sunumları temizle',
    :view    => 'sunumları görüntüle', #gorev acıklamaları yapılmıstır.
    :run     => 'sunumları sun',
    :optim   => 'resimleri iyileştir',
    :default => 'öntanımlı görev',
}

presentation   = {}
tag            = {}

class File # sınıf kullanarak dosya yolunun alınması islemi.  
  @@absolute_path_here = Pathname.new(Pathname.pwd) #dizinin yolu.
  def self.to_herepath(path)
    Pathname.new(File.expand_path(path)).relative_path_from(@@absolute_path_here).to_s
  end
  def self.to_filelist(path)
    File.directory?(path) ? #dosya yolu aynı olan dosyaları listeleme görevi yapar.
      FileList[File.join(path, '*')].select { |f| File.file?(f) } :
      [path]
  end
end

def png_comment(file, string) # dosya yolundaki stringi yorumlar.
  require 'chunky_png' #chunky png sınıfını cagır.
  require 'oily_png'   #oily_png sınıfını cagır.

  image = ChunkyPNG::Image.from_file(file) #resimler uzerinde duzeltme yapmamızı saglar.
  image.metadata['Comment'] = 'raked' #acılan dosyadaki raked yoorumunu yapmaktadır.
  image.save(file)
end

def png_optim(file, threshold=40000) #boyutu 4000 den kucuk olan resimler alınacak.
  return if File.new(file).size < threshold #boyutlandırılıp cıkısa aktarma yapılacak.
  sh "pngnq -f -e .png-nq #{file}"
  out = "#{file}-nq"
  if File.exist?(out) #File ın cıkısını kontrol et.
    $?.success? ? File.rename(out, file) : File.delete(out) #duruma bakarak out u silebilirsin.
  end
  png_comment(file, 'raked')
end

def jpg_optim(file)
  sh "jpegoptim -q -m80 #{file}"
  sh "mogrify -comment 'raked' #{file}"
end

def optim
  pngs, jpgs = FileList["**/*.png"], FileList["**/*.jpg", "**/*.jpeg"]

  [pngs, jpgs].each do |a|
    a.reject! { |f| %x{identify -format '%c' #{f}} =~ /[Rr]aked/ } #raked olanları listeden cıkar.
  end

  (pngs + jpgs).each do |f| # pngs ve jpgs dosyalarının içerisinde gezinmemizi saglar.
    w, h = %x{identify -format '%[fx:w] %[fx:h]' #{f}}.split.map { |e| e.to_i }
    size, i = [w, h].each_with_index.max #boyutlar kontrol ediliyor.
    if size > IMAGE_GEOMETRY[i] #boyutlandır.
      arg = (i > 0 ? 'x' : '') + IMAGE_GEOMETRY[i].to_s
      sh "mogrify -resize #{arg} #{f}"
    end
  end

  pngs.each { |f| png_optim(f) }
  jpgs.each { |f| jpg_optim(f) }

  (pngs + jpgs).each do |f|
    name = File.basename f
    FileList["*/*.md"].each do |src|
      sh "grep -q '(.*#{name})' #{src} && touch #{src}"
    end
  end
end

default_conffile = File.expand_path(DEFAULT_CONFFILE) #dosya yolunu al.

FileList[File.join(PRESENTATION_DIR, "[^_.]*")].each do |dir| #dizinin içerisinde [^_.]* ile baslayan karakterler.
  next unless File.directory?(dir)
  chdir dir do
    name = File.basename(dir)
    conffile = File.exists?('presentation.cfg') ? 'presentation.cfg' : default_conffile
    config = File.open(conffile, "r") do |f| #dosya aç içinde dolas.
      PythonConfig::ConfigParser.new(f)
    end

    landslide = config['landslide'] #congig içerisindeki landslide kısmını al.
    if ! landslide
      $stderr.puts "#{dir}: 'landslide' bölümü tanımlanmamış" #hata cıkısı olarak burayı goster.
      exit 1
    end

    if landslide['destination']
      $stderr.puts "#{dir}: 'destination' ayarı kullanılmış; hedef dosya belirtilmeyin"
      exit 1
    end

    if File.exists?('index.md')
      base = 'index'
      ispublic = true
    elsif File.exists?('presentation.md')
      base = 'presentation'
      ispublic = false
    else
      $stderr.puts "#{dir}: sunum kaynağı 'presentation.md' veya 'index.md' olmalı"
      exit 1
    end

    basename = base + '.html'
    thumbnail = File.to_herepath(base + '.png')
    target = File.to_herepath(basename)

    deps = []
    (DEPEND_ALWAYS + landslide.values_at(*DEPEND_KEYS)).compact.each do |v|
      deps += v.split.select { |p| File.exists?(p) }.map { |p| File.to_filelist(p) }.flatten
    end

    deps.map! { |e| File.to_herepath(e) } #desp içerisinde map islevini yap.
    deps.delete(target) #target degiskenini sil.
    deps.delete(thumbnail) #thumbnail degiskenini sil.

    tags = []

   presentation[dir] = {
      :basename  => basename,	# üreteceğimiz sunum dosyasının baz adı
      :conffile  => conffile,	# landslide konfigürasyonu (mutlak dosya yolu)
      :deps      => deps,	# sunum bağımlılıkları
      :directory => dir,	# sunum dizini (tepe dizine göreli)
      :name      => name,	# sunum ismi
      :public    => ispublic,	# sunum dışarı açık mı
      :tags      => tags,	# sunum etiketleri
      :target    => target,	# üreteceğimiz sunum dosyası (tepe dizine göreli)
      :thumbnail => thumbnail, 	# sunum için küçük resim
    }
  end
end

presentation.each do |k, v|
  v[:tags].each do |t|
    tag[t] ||= []
    tag[t] << k
  end
end

tasktab = Hash[*TASKS.map { |k, v| [k, { :desc => v, :tasks => [] }] }.flatten]

presentation.each do |presentation, data| #presentation icerisinde dolas ve etiketle.
  ns = namespace presentation do
    file data[:target] => data[:deps] do |t| #gorev etiketleri.
      chdir presentation do
        sh "landslide -i #{data[:conffile]}" #kabukta landslide -1 dondurur.
        sh 'sed -i -e "s/^\([[:blank:]]*var hiddenContext = \)false\(;[[:blank:]]*$\)/\1true\2/" presentation.html'
        unless data[:basename] == 'presentation.html'
          mv 'presentation.html', data[:basename] #presentation.html olarak değistir.
        end
      end
    end

    file data[:thumbnail] => data[:target] do
      next unless data[:public]
      sh "cutycapt " +
          "--url=file://#{File.absolute_path(data[:target])}#slide1 " +
          "--out=#{data[:thumbnail]} " +
          "--user-style-string='div.slides { width: 900px; overflow: hidden; }' " +
          "--min-width=1024 " +
          "--min-height=768 " +
          "--delay=1000"
      sh "mogrify -resize 240 #{data[:thumbnail]}"
      png_optim(data[:thumbnail])
    end

    task :optim do
      chdir presentation do
        optim
      end
    end

    task :index => data[:thumbnail] #indeksi calıstır.

    task :build => [:optim, data[:target], :index]

    task :view do
      if File.exists?(data[:target]) #var olup olmadıgı kontrol ediliyor.
        sh "touch #{data[:directory]}; #{browse_command data[:target]}"
      else
        $stderr.puts "#{data[:target]} bulunamadı; önce inşa edin"
      end
    end

    task :run => [:build, :view] #run ı calıstırmak için build ve view kullanılıyor.

    task :clean do
      rm_f data[:target] #target siliniyor.
      rm_f data[:thumbnail] #thumbnail siliniyor.
    end

    task :default => :build #build calıstırıılıyor.
  end

  ns.tasks.map(&:to_s).each do |t| #np uzerinde map islevi yap.
    _, _, name = t.partition(":").map(&:to_sym)
    next unless tasktab[name]
    tasktab[name][:tasks] << t
  end
end

namespace :p do #isim uzayında gorev olustur.
  tasktab.each do |name, info|
    desc info[:desc]
    task name => info[:tasks]
    task name[0] => name
  end

  task :build do
    index = YAML.load_file(INDEX_FILE) || {}
    presentations = presentation.values.select { |v| v[:public] }.map { |v| v[:directory] }.sort
    unless index and presentations == index['presentations'] #indesk olmazsaq presentation indeks numaralarına esittir.
      index['presentations'] = presentations
      File.open(INDEX_FILE, 'w') do |f|
        f.write(index.to_yaml)
        f.write("---\n") #indeks 1 yaml yapılıp içerisine yazılıyor.
      end
    end
  end

  desc "sunum menüsü"
  task :menu do
    lookup = Hash[
      *presentation.sort_by do |k, v|
        File.mtime(v[:directory])
      end
      .reverse
      .map { |k, v| [v[:name], k] }
      .flatten
    ]
    name = choose do |menu|
      menu.default = "1"
      menu.prompt = color(
        'Lütfen sunum seçin ', :headline
      ) + '[' + color("#{menu.default}", :special) + ']'
      menu.choices(*lookup.keys)
    end
    directory = lookup[name]
    Rake::Task["#{directory}:run"].invoke #rake verilen dizin ile calıstırılır.
  end
  task :m => :menu
end
 
desc "sunum menüsü" 
task :p => ["p:menu"] #menude p iletisiyle calıstır.
task :presentation => :p #presentationdan gelen veriyle calıstır.
