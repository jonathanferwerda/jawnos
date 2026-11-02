#!/usr/bin/perl
#
# language.pl - the house's interface languages.
#
# Loaded from subroutines.pl (require "./perl/language.pl") so every worker, script
# and template sees the same catalog. A string lives in the `en` catalog first;
# another language overrides it. A key with no translation in the chosen
# language falls back to English, then to the key itself, so a missing line is
# never a blank label.
#
# The list is English first (the default), then Mandarin, French, Spanish,
# German and Portuguese as the first choices, then the ten most widely spoken
# languages not already listed. `login.pl` (the setup wizard) and the Misc
# panel read this same list, so the install and the running app never disagree.
package language;

use strict;
use warnings;
use utf8;
use File::Basename qw(dirname);
use JSON::PP ();

# this file lives in perl/, and the catalogs it reads are under the tree's i18n/
our $ROOT = dirname(dirname(__FILE__));

our $DEFAULT = 'en';

our @languages = (
	{ code => 'en', name => 'English',    native => 'English',           dir => 'ltr' },
	{ code => 'zh', name => 'Mandarin',   native => '中文',               dir => 'ltr' },
	{ code => 'fr', name => 'French',     native => 'Français',           dir => 'ltr' },
	{ code => 'es', name => 'Spanish',    native => 'Español',            dir => 'ltr' },
	{ code => 'de', name => 'German',     native => 'Deutsch',            dir => 'ltr' },
	{ code => 'pt', name => 'Portuguese', native => 'Português',          dir => 'ltr' },
	{ code => 'hi', name => 'Hindi',      native => 'हिन्दी',               dir => 'ltr' },
	{ code => 'ar', name => 'Arabic',     native => 'العربية',              dir => 'rtl' },
	{ code => 'bn', name => 'Bengali',    native => 'বাংলা',                dir => 'ltr' },
	{ code => 'ru', name => 'Russian',    native => 'Русский',            dir => 'ltr' },
	{ code => 'ja', name => 'Japanese',   native => '日本語',               dir => 'ltr' },
	{ code => 'pa', name => 'Punjabi',    native => 'ਪੰਜਾਬੀ',               dir => 'ltr' },
	{ code => 'id', name => 'Indonesian', native => 'Bahasa Indonesia',   dir => 'ltr' },
	{ code => 'ko', name => 'Korean',     native => '한국어',               dir => 'ltr' },
	{ code => 'it', name => 'Italian',    native => 'Italiano',           dir => 'ltr' },
	{ code => 'tr', name => 'Turkish',    native => 'Türkçe',             dir => 'ltr' },
);

our %by_code = map { $_->{'code'} => $_ } @languages;

# A language code the app may use. Anything unknown reads as English; a stored
# preference is never allowed to break a page because a catalog was removed.
sub valid {
	my ($code) = @_;
	$code = $DEFAULT unless defined $code && length $code;
	return $by_code{$code} ? $code : $DEFAULT;
}

sub definition {
	my ($code) = @_;
	return $by_code{ &valid($code) };
}

sub dir_for {
	my ($code) = @_;
	my $d = &definition($code);
	return $d->{'dir'} || 'ltr';
}

sub label {
	my ($code) = @_;
	my $d = &definition($code);
	return $d->{'native'} || $d->{'name'} || 'English';
}

# ---------------------------------------------------------------------------
# catalogs
# ---------------------------------------------------------------------------
our %catalog;

# Each language's catalogue lives in its own file under perl/language/, so no
# single source file is enormous. A fragment assigns its whole hashref; the
# loops below then add Internet's core labels and backfill anything missing
# from English. Order matches @languages above.
require "./perl/language/en.pl";
require "./perl/language/zh.pl";
require "./perl/language/fr.pl";
require "./perl/language/es.pl";
require "./perl/language/de.pl";
require "./perl/language/pt.pl";
require "./perl/language/hi.pl";
require "./perl/language/ar.pl";
require "./perl/language/bn.pl";
require "./perl/language/ru.pl";
require "./perl/language/ja.pl";
require "./perl/language/pa.pl";
require "./perl/language/id.pl";
require "./perl/language/ko.pl";
require "./perl/language/it.pl";
require "./perl/language/tr.pl";


# Internet's own labels. They are written in every interface language here
# rather than left to the English backfill, because they are core labels the
# app's toolbar and tab strip show on every machine.
my @internet_keys = qw( internet browse web open_browser measure_page usage_today time_spent usage_none );
my %internet_labels = (
	en => [ 'Internet', 'Browse', 'Web', 'Open browser', 'Measure this page', 'Site time today', 'Time spent', 'No times recorded yet' ],
	zh => [ '互联网', '浏览', '网页', '打开浏览器', '测量此页面', '今日网站时间', '所用时间', '尚无记录' ],
	fr => [ 'Internet', 'Parcourir', 'Web', 'Ouvrir le navigateur', 'Mesurer cette page', 'Temps passé aujourd\'hui', 'Temps passé', 'Aucun temps enregistré' ],
	es => [ 'Internet', 'Navegar', 'Web', 'Abrir el navegador', 'Medir esta página', 'Tiempo en sitios hoy', 'Tiempo empleado', 'Aún no hay tiempos registrados' ],
	de => [ 'Internet', 'Surfen', 'Web', 'Browser öffnen', 'Diese Seite messen', 'Website-Zeit heute', 'Verbrachte Zeit', 'Noch keine Zeiten erfasst' ],
	pt => [ 'Internet', 'Navegar', 'Web', 'Abrir navegador', 'Medir esta página', 'Tempo em sites hoje', 'Tempo gasto', 'Ainda não há tempos registrados' ],
	hi => [ 'इंटरनेट', 'ब्राउज़ करें', 'वेब', 'ब्राउज़र खोलें', 'इस पृष्ठ को मापें', 'आज साइट पर समय', 'बिताया समय', 'अभी कोई समय दर्ज नहीं' ],
	ar => [ 'الإنترنت', 'تصفح', 'الويب', 'افتح المتصفح', 'قياس هذه الصفحة', 'وقت المواقع اليوم', 'الوقت المستغرق', 'لا توجد أوقات مسجلة بعد' ],
	bn => [ 'ইন্টারনেট', 'ব্রাউজ', 'ওয়েব', 'ব্রাউজার খুলুন', 'এই পৃষ্ঠাটি মাপুন', 'আজ সাইটে সময়', 'ব্যয়িত সময়', 'এখনও কোনো সময় রেকর্ড হয়নি' ],
	ru => [ 'Интернет', 'Обзор', 'Веб', 'Открыть браузер', 'Измерить эту страницу', 'Время на сайтах сегодня', 'Затраченное время', 'Время ещё не записано' ],
	ja => [ 'インターネット', 'ブラウズ', 'ウェブ', 'ブラウザを開く', 'このページを測定', '今日のサイト時間', '費やした時間', 'まだ記録がありません' ],
	pa => [ 'ਇੰਟਰਨੈੱਟ', 'ਬ੍ਰਾਊਜ਼', 'ਵੈੱਬ', 'ਬ੍ਰਾਊਜ਼ਰ ਖੋਲ੍ਹੋ', 'ਇਸ ਪੰਨੇ ਨੂੰ ਮਾਪੋ', 'ਅੱਜ ਸਾਈਟ ਦਾ ਸਮਾਂ', 'ਬਿਤਾਇਆ ਸਮਾਂ', 'ਹਾਲੇ ਕੋਈ ਸਮਾਂ ਦਰਜ ਨਹੀਂ' ],
	id => [ 'Internet', 'Jelajah', 'Web', 'Buka peramban', 'Ukur halaman ini', 'Waktu situs hari ini', 'Waktu terpakai', 'Belum ada waktu tercatat' ],
	ko => [ '인터넷', '탐색', '웹', '브라우저 열기', '이 페이지 측정', '오늘의 사이트 시간', '사용한 시간', '아직 기록된 시간이 없습니다' ],
	it => [ 'Internet', 'Naviga', 'Web', 'Apri il browser', 'Misura questa pagina', 'Tempo sui siti oggi', 'Tempo trascorso', 'Nessun tempo registrato' ],
	tr => [ 'İnternet', 'Göz at', 'Web', 'Tarayıcıyı aç', 'Bu sayfayı ölç', 'Bugün site süresi', 'Geçirilen süre', 'Henüz süre kaydedilmedi' ],
);
foreach my $code ( keys %internet_labels ) {
	my %add;
	@add{@internet_keys} = @{$internet_labels{$code}};
	$catalog{$code} = { %{$catalog{$code} || {}}, %add };
}

# Configure -> Plat -> QA. These are core labels on a settings panel, so they
# are written here in every interface language rather than left to the English
# backfill. The surrounding explanation is help text and goes through subs::ui.
my @qa_keys = qw( configure.qa_nightly configure.qa_nightly_device configure.qa_this_machine
	configure.qa_ready configure.qa_not_ready configure.qa_missing configure.qa_install
	configure.qa_check configure.qa_checking configure.qa_note_limit );
my %qa_labels = (
	en => [ 'QA nightly', 'Nightly machine', 'This machine (local)', 'Ready', 'Not ready', 'Missing', 'Install', 'Check again', 'Checking…', 'Notes per night' ],
	zh => [ 'QA 夜检', '夜间运行的机器', '本机（本地）', '就绪', '未就绪', '缺少', '安装', '重新检查', '正在检查…', '每晚笔记数' ],
	fr => [ 'QA nocturne', 'Machine de nuit', 'Cette machine (locale)', 'Prêt', 'Pas prêt', 'Manquant', 'Installer', 'Vérifier à nouveau', 'Vérification…', 'Notes par nuit' ],
	es => [ 'QA nocturno', 'Máquina nocturna', 'Esta máquina (local)', 'Listo', 'No listo', 'Falta', 'Instalar', 'Comprobar de nuevo', 'Comprobando…', 'Notas por noche' ],
	de => [ 'Nächtliche QA', 'Nachtmaschine', 'Diese Maschine (lokal)', 'Bereit', 'Nicht bereit', 'Fehlt', 'Installieren', 'Erneut prüfen', 'Prüfe…', 'Notizen pro Nacht' ],
	pt => [ 'QA noturno', 'Máquina noturna', 'Esta máquina (local)', 'Pronto', 'Não pronto', 'Falta', 'Instalar', 'Verificar novamente', 'Verificando…', 'Notas por noite' ],
	hi => [ 'रात्रि QA', 'रात्रि मशीन', 'यह मशीन (स्थानीय)', 'तैयार', 'तैयार नहीं', 'अनुपस्थित', 'इंस्टॉल करें', 'फिर जाँचें', 'जाँच हो रही है…', 'प्रति रात नोट्स' ],
	ar => [ 'فحص QA الليلي', 'جهاز الفحص الليلي', 'هذا الجهاز (محلي)', 'جاهز', 'غير جاهز', 'مفقود', 'تثبيت', 'تحقق مرة أخرى', 'جارٍ التحقق…', 'ملاحظات في الليلة' ],
	bn => [ 'রাত্রিকালীন QA', 'রাত্রিকালীন মেশিন', 'এই মেশিন (স্থানীয়)', 'প্রস্তুত', 'প্রস্তুত নয়', 'অনুপস্থিত', 'ইনস্টল করুন', 'আবার পরীক্ষা করুন', 'পরীক্ষা চলছে…', 'প্রতি রাতে নোট' ],
	ru => [ 'Ночная QA', 'Ночная машина', 'Эта машина (локально)', 'Готово', 'Не готово', 'Отсутствует', 'Установить', 'Проверить снова', 'Проверка…', 'Заметок за ночь' ],
	ja => [ '夜間QA', '夜間実行マシン', 'このマシン（ローカル）', '準備完了', '未準備', '不足', 'インストール', '再確認', '確認中…', '1晩のノート数' ],
	pa => [ 'ਰਾਤ ਦੀ QA', 'ਰਾਤ ਦੀ ਮਸ਼ੀਨ', 'ਇਹ ਮਸ਼ੀਨ (ਸਥਾਨਕ)', 'ਤਿਆਰ', 'ਤਿਆਰ ਨਹੀਂ', 'ਗੁੰਮ', 'ਇੰਸਟਾਲ ਕਰੋ', 'ਦੁਬਾਰਾ ਜਾਂਚੋ', 'ਜਾਂਚ ਹੋ ਰਹੀ ਹੈ…', 'ਹਰ ਰਾਤ ਨੋਟਸ' ],
	id => [ 'QA malam', 'Mesin malam', 'Mesin ini (lokal)', 'Siap', 'Belum siap', 'Hilang', 'Pasang', 'Periksa lagi', 'Memeriksa…', 'Catatan per malam' ],
	ko => [ '야간 QA', '야간 실행 기기', '이 기기(로컬)', '준비됨', '준비 안 됨', '누락', '설치', '다시 확인', '확인 중…', '밤당 노트 수' ],
	it => [ 'QA notturno', 'Macchina notturna', 'Questa macchina (locale)', 'Pronto', 'Non pronto', 'Mancante', 'Installa', 'Controlla di nuovo', 'Controllo…', 'Note per notte' ],
	tr => [ 'Gece QA', 'Gece makinesi', 'Bu makine (yerel)', 'Hazır', 'Hazır değil', 'Eksik', 'Kur', 'Yeniden denetle', 'Denetleniyor…', 'Gece başına not' ],
);
foreach my $code ( keys %qa_labels ) {
	my %add;
	@add{@qa_keys} = @{$qa_labels{$code}};
	$catalog{$code} = { %{$catalog{$code} || {}}, %add };
}

foreach my $code ( keys %catalog ) {
	next if $code eq 'en';
	foreach my $key ( keys %{$catalog{'en'}} ) {
		$catalog{$code}{$key} = $catalog{'en'}{$key} unless exists $catalog{$code}{$key};
	}
}

sub translate {
	my ( $code, $key, @args ) = @_;
	return '' unless defined $key;
	$code = &valid($code);
	my $string = $catalog{$code}{$key};
	$string = $catalog{$DEFAULT}{$key} unless defined $string;
	$string = $key unless defined $string;
	if (@args) {
		$string =~ s/\{(\d+)\}/defined $args[$1] ? $args[$1] : ''/ge;
	}
	return $string;
}

# The catalog a page hands to its scripts. Only the current language, with the
# English fallback already folded in, so a label is never missing.
sub for_javascript {
	my ($code) = @_;
	$code = &valid($code);
	my %out = %{$catalog{$DEFAULT}};
	foreach my $key ( keys %{$catalog{$code}} ) {
		$out{$key} = $catalog{$code}{$key};
	}
	return \%out;
}

# The generated UI/help catalog (i18n/ui-<code>.json). It is loaded once per
# process and only when a server-side surface asks for a string; the browser
# gets the same file through /i18n/ui-<code>.js.
our %ui_catalog_cache;
sub ui_catalog {
	my ($code) = @_;
	$code = &valid($code);
	return {} if $code eq $DEFAULT;
	return $ui_catalog_cache{$code} if $ui_catalog_cache{$code};
	my $file = "$ROOT/i18n/ui-$code.json";
	unless ( -e $file ) {
		$ui_catalog_cache{$code} = {};
		return $ui_catalog_cache{$code};
	}
	my $raw = do {
		local $/;
		open my $fh, '<:raw', $file or return {};
		<$fh>;
	};
	my $d = eval { JSON::PP->new->utf8->decode($raw) };
	$ui_catalog_cache{$code} = ref $d eq 'HASH' ? $d : {};
	return $ui_catalog_cache{$code};
}

sub ui_translate {
	my ( $code, $string ) = @_;
	return $string unless defined $string && length $string;
	my $c = &ui_catalog($code);
	return $c->{$string} if defined $c->{$string} && length $c->{$string};
	return $string;
}

# ---------------------------------------------------------------------------
# On-demand translation languages
# ---------------------------------------------------------------------------
# The interface languages above are the ones with hand-written core labels.
# The Guide's translation engine can also translate into the languages below on
# request; the list is what the engine offers, not a promise that every model is
# equally good at every one. DeepSeek, Gemini, Claude and the other configured
# models are broadly multilingual; the model named in Configure -> Plat is the
# one that runs the translation.
our $translation_languages_cache;
sub translation_languages {
	return $translation_languages_cache if $translation_languages_cache;
	my @out = map {
		{ code => $_->{'code'}, native => $_->{'native'}, name => $_->{'name'}, interface => 1 }
	} @languages;
	my %seen = map { $_->{'code'} => 1 } @out;
	my $extra = <<'LIST';
zh-TW|繁體中文|Traditional Chinese
af|Afrikaans|Afrikaans
sq|Shqip|Albanian
am|አማርኛ|Amharic
hy|Հայերեն|Armenian
az|Azərbaycanca|Azerbaijani
eu|Euskara|Basque
be|Беларуская|Belarusian
bs|Bosanski|Bosnian
bg|Български|Bulgarian
ca|Català|Catalan
ceb|Cebuano|Cebuano
ny|Chichewa|Chichewa
co|Corsu|Corsican
hr|Hrvatski|Croatian
cs|Čeština|Czech
da|Dansk|Danish
nl|Nederlands|Dutch
eo|Esperanto|Esperanto
et|Eesti|Estonian
tl|Filipino|Filipino
fi|Suomi|Finnish
fy|Frysk|Frisian
gl|Galego|Galician
ka|ქართული|Georgian
el|Ελληνικά|Greek
gu|ગુજરાતી|Gujarati
ht|Kreyòl ayisyen|Haitian Creole
ha|Hausa|Hausa
haw|ʻŌlelo Hawaiʻi|Hawaiian
he|עברית|Hebrew
hmn|Hmoob|Hmong
hu|Magyar|Hungarian
is|Íslenska|Icelandic
ig|Igbo|Igbo
ga|Gaeilge|Irish
jv|Basa Jawa|Javanese
kn|ಕನ್ನಡ|Kannada
kk|Қазақша|Kazakh
km|ខ្មែរ|Khmer
rw|Ikinyarwanda|Kinyarwanda
ky|Кыргызча|Kyrgyz
lo|ລາວ|Lao
la|Latina|Latin
lv|Latviešu|Latvian
lt|Lietuvių|Lithuanian
lb|Lëtzebuergesch|Luxembourgish
mk|Македонски|Macedonian
mg|Malagasy|Malagasy
ms|Bahasa Melayu|Malay
ml|മലയാളം|Malayalam
mt|Malti|Maltese
mi|Te Reo Māori|Māori
mr|मराठी|Marathi
mn|Монгол|Mongolian
my|မြန်မာ|Burmese
ne|नेपाली|Nepali
no|Norsk|Norwegian
or|ଓଡ଼ିଆ|Odia
ps|پښتو|Pashto
fa|فارسی|Persian
pl|Polski|Polish
ro|Română|Romanian
sm|Gagana Samoa|Samoan
gd|Gàidhlig|Scottish Gaelic
sr|Српски|Serbian
st|Sesotho|Sesotho
sn|ChiShona|Shona
sd|سنڌي|Sindhi
si|සිංහල|Sinhala
sk|Slovenčina|Slovak
sl|Slovenščina|Slovenian
so|Soomaali|Somali
su|Basa Sunda|Sundanese
sw|Kiswahili|Swahili
sv|Svenska|Swedish
tg|Тоҷикӣ|Tajik
ta|தமிழ்|Tamil
tt|Татарча|Tatar
te|తెలుగు|Telugu
th|ไทย|Thai
tk|Türkmençe|Turkmen
uk|Українська|Ukrainian
ur|اردو|Urdu
ug|ئۇيغۇرچە|Uyghur
uz|Oʻzbekcha|Uzbek
cy|Cymraeg|Welsh
xh|isiXhosa|Xhosa
yi|ייִדיש|Yiddish
yo|Yorùbá|Yoruba
zu|isiZulu|Zulu
LIST
	foreach my $line ( split /\n/, $extra ) {
		next unless $line =~ /\S/;
		my ( $code, $native, $name ) = split /\|/, $line, 3;
		next unless defined $code && length $code && !$seen{$code}++;
		push @out, { code => $code, native => $native, name => $name, interface => 0 };
	}
	$translation_languages_cache = \@out;
	return $translation_languages_cache;
}

our %translation_alias = (
	chinese => 'zh', mandarin => 'zh', cantonese => 'zh-TW', 'traditional chinese' => 'zh-TW',
	castilian => 'es', farsi => 'fa', persian => 'fa', 'brazilian portuguese' => 'pt',
	'brazilian' => 'pt', 'pt-br' => 'pt', 'pt_br' => 'pt', 'zh-cn' => 'zh', 'zh-hans' => 'zh',
	'zh-tw' => 'zh-TW', 'zh-hant' => 'zh-TW', 'simplified chinese' => 'zh',
	'flemish' => 'nl', 'tagalog' => 'tl', 'burmese' => 'my', 'myanmar' => 'my',
	'norwegian bokmal' => 'no', 'norwegian bokmål' => 'no', 'scots gaelic' => 'gd',
	'gaelic' => 'gd', 'haitian' => 'ht', 'kreyol' => 'ht', 'moldovan' => 'ro',
	'serbo-croatian' => 'sr', 'hindi' => 'hi', 'bengali' => 'bn', 'bangla' => 'bn',
);

# Resolve a language named by code, native name, English name or alias. The
# Guide hands over the person's own words, so this is deliberately forgiving.
sub translation_language {
	my ($value) = @_;
	return undef unless defined $value;
	my $want = $value;
	$want =~ s/^\s+|\s+$//g;
	return undef unless length $want;
	my $lc = lc $want;
	my $list = &translation_languages();
	foreach my $l ( @{$list} ) {
		return $l if lc( $l->{'code'} ) eq $lc;
	}
	foreach my $l ( @{$list} ) {
		return $l if lc( $l->{'native'} ) eq $lc || lc( $l->{'name'} ) eq $lc;
	}
	$lc =~ s/[_-]+/ /g;
	my $raw_lc = lc $want;
	foreach my $l ( @{$list} ) {
		my $n = lc $l->{'name'};
		$n =~ s/[_-]+/ /g;
		return $l if $n eq $lc;
	}
	my $alias = $translation_alias{$raw_lc} || $translation_alias{$lc};
	if ($alias) {
		foreach my $l ( @{$list} ) { return $l if $l->{'code'} eq $alias; }
	}
	return undef;
}

1;
