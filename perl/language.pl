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


# The Folders toolbar's Sync drawer. It is a core label, so it is written in
# every interface language here rather than left to the English backfill; the
# sentences around the queue go through subs::ui/jawnosT on demand.
my @folders_sync_keys = qw( folders.sync );
my %folders_sync_labels = (
	en => [ 'Sync' ],
	zh => [ '同步' ],
	fr => [ 'Synchroniser' ],
	es => [ 'Sincronizar' ],
	de => [ 'Synchronisieren' ],
	pt => [ 'Sincronizar' ],
	hi => [ 'सिंक करें' ],
	ar => [ 'مزامنة' ],
	bn => [ 'সিঙ্ক' ],
	ru => [ 'Синхронизировать' ],
	ja => [ '同期' ],
	pa => [ 'ਸਿੰਕ' ],
	id => [ 'Sinkronkan' ],
	ko => [ '동기화' ],
	it => [ 'Sincronizza' ],
	tr => [ 'Eşitle' ],
);
foreach my $code ( keys %folders_sync_labels ) {
	my %add;
	@add{@folders_sync_keys} = @{$folders_sync_labels{$code}};
	$catalog{$code} = { %{$catalog{$code} || {}}, %add };
}


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

# The Leave menu's choices. These are core labels on the start menu and its
# dialog, so they are written here in every interface language; the sentence
# under each choice is UI text and goes through jawnosT/sub::ui on demand.
my @power_keys = qw( power_leave power_exit power_restart power_shutdown power_sleep );
my %power_labels = (
en => [ 'Leave', 'Exit', 'Restart', 'Shut down', 'Sleep' ],
zh => [ '离开', '退出', '重启', '关机', '睡眠' ],
fr => [ 'Quitter', 'Quitter', 'Redémarrer', 'Éteindre', 'Veille' ],
es => [ 'Salir', 'Salir', 'Reiniciar', 'Apagar', 'Suspender' ],
de => [ 'Verlassen', 'Beenden', 'Neustart', 'Herunterfahren', 'Standby' ],
pt => [ 'Sair', 'Sair', 'Reiniciar', 'Desligar', 'Suspender' ],
hi => [ 'छोड़ें', 'बाहर निकलें', 'पुनः चालू करें', 'बंद करें', 'स्लीप' ],
ar => [ 'مغادرة', 'خروج', 'إعادة التشغيل', 'إيقاف التشغيل', 'سكون' ],
bn => [ 'প্রস্থান', 'প্রস্থান', 'পুনরায় চালু করুন', 'বন্ধ করুন', 'স্লিপ' ],
ru => [ 'Выйти', 'Выйти', 'Перезагрузить', 'Выключить', 'Сон' ],
ja => [ '退出', '終了', '再起動', 'シャットダウン', 'スリープ' ],
pa => [ 'ਛੱਡੋ', 'ਬਾਹਰ ਜਾਓ', 'ਮੁੜ ਚਾਲੂ ਕਰੋ', 'ਬੰਦ ਕਰੋ', 'ਸਲੀਪ' ],
id => [ 'Keluar', 'Keluar', 'Mulai ulang', 'Matikan', 'Tidur' ],
ko => [ '나가기', '종료', '다시 시작', '시스템 종료', '절전' ],
it => [ 'Esci', 'Esci', 'Riavvia', 'Spegni', 'Sospendi' ],
tr => [ 'Çık', 'Çık', 'Yeniden başlat', 'Kapat', 'Uyku' ],
);
foreach my $code ( keys %power_labels ) {
	my %add;
	@add{@power_keys} = @{$power_labels{$code}};
	$catalog{$code} = { %{$catalog{$code} || {}}, %add };
}

# The Power app's own labels. These are core labels on the app window and the
# taskbar widget, so they are written in every interface language here rather
# than left to the English backfill. The sentences around them go through
# subs::ui and are translated on demand.
my @power_app_keys = qw( power power_ac power_battery power_auto power_saver power_balanced power_performance power_cpu_speed power_time_left power_time_to_full power_charging power_discharging power_full power_not_available );
my %power_app_labels = (
en => [ 'Power', 'On mains', 'On battery', 'Auto', 'Power saver', 'Balanced', 'Performance', 'CPU speed', 'Time left', 'Time to full', 'Charging', 'Discharging', 'Full', 'Not available on this machine' ],
zh => [ '电源', '接入电源', '使用电池', '自动', '节能', '均衡', '性能', 'CPU 速度', '剩余时间', '充满还需', '充电中', '放电中', '已充满', '此机器不可用' ],
fr => [ 'Alimentation', 'Sur secteur', 'Sur batterie', 'Auto', 'Économiseur', 'Équilibré', 'Performance', 'Vitesse du CPU', 'Temps restant', 'Temps avant charge complète', 'En charge', 'En décharge', 'Pleine', 'Indisponible sur cette machine' ],
es => [ 'Energía', 'En red eléctrica', 'Con batería', 'Automático', 'Ahorro de energía', 'Equilibrado', 'Rendimiento', 'Velocidad de la CPU', 'Tiempo restante', 'Tiempo para cargar', 'Cargando', 'Descargando', 'Llena', 'No disponible en esta máquina' ],
de => [ 'Energie', 'Am Netz', 'Im Akkubetrieb', 'Automatisch', 'Energiesparmodus', 'Ausgeglichen', 'Leistung', 'CPU-Geschwindigkeit', 'Restzeit', 'Zeit bis voll', 'Wird geladen', 'Entlädt', 'Voll', 'Auf dieser Maschine nicht verfügbar' ],
pt => [ 'Energia', 'Na tomada', 'Na bateria', 'Automático', 'Economia de energia', 'Equilibrado', 'Desempenho', 'Velocidade da CPU', 'Tempo restante', 'Tempo até cheio', 'Carregando', 'Descarregando', 'Cheia', 'Indisponível nesta máquina' ],
hi => [ 'पावर', 'मुख्य विद्युत पर', 'बैटरी पर', 'स्वतः', 'बिजली बचत', 'संतुलित', 'प्रदर्शन', 'CPU गति', 'शेष समय', 'पूर्ण होने में समय', 'चार्ज हो रहा है', 'डिस्चार्ज हो रहा है', 'पूर्ण', 'इस मशीन पर उपलब्ध नहीं' ],
ar => [ 'الطاقة', 'على الكهرباء', 'على البطارية', 'تلقائي', 'توفير الطاقة', 'متوازن', 'الأداء', 'سرعة المعالج', 'الوقت المتبقي', 'الوقت حتى الامتلاء', 'جارٍ الشحن', 'تفريغ', 'ممتلئة', 'غير متاح على هذا الجهاز' ],
bn => [ 'পাওয়ার', 'মেইনসে', 'ব্যাটারিতে', 'স্বয়ংক্রিয়', 'বিদ্যুৎ সাশ্রয়', 'ভারসাম্যপূর্ণ', 'কর্মক্ষমতা', 'CPU গতি', 'বাকি সময়', 'পূর্ণ হতে সময়', 'চার্জ হচ্ছে', 'ডিসচার্জ হচ্ছে', 'পূর্ণ', 'এই মেশিনে উপলব্ধ নয়' ],
ru => [ 'Питание', 'От сети', 'От батареи', 'Авто', 'Экономия энергии', 'Сбалансированный', 'Производительность', 'Скорость ЦП', 'Осталось', 'До полной зарядки', 'Заряжается', 'Разряжается', 'Полная', 'Недоступно на этой машине' ],
ja => [ '電源', '電源接続時', 'バッテリー時', '自動', '省電力', 'バランス', 'パフォーマンス', 'CPU速度', '残り時間', '満充電まで', '充電中', '放電中', '満充電', 'このマシンでは利用できません' ],
pa => [ 'ਪਾਵਰ', 'ਮੇਨਸ ਤੇ', 'ਬੈਟਰੀ ਤੇ', 'ਆਟੋ', 'ਬਿਜਲੀ ਬਚਤ', 'ਸੰਤੁਲਿਤ', 'ਪ੍ਰਦਰਸ਼ਨ', 'CPU ਗਤੀ', 'ਬਾਕੀ ਸਮਾਂ', 'ਪੂਰਾ ਹੋਣ ਤੱਕ ਸਮਾਂ', 'ਚਾਰਜ ਹੋ ਰਿਹਾ', 'ਡਿਸਚਾਰਜ ਹੋ ਰਿਹਾ', 'ਪੂਰੀ', 'ਇਸ ਮਸ਼ੀਨ ਤੇ ਉਪਲਬਧ ਨਹੀਂ' ],
id => [ 'Daya', 'Dari listrik', 'Dari baterai', 'Otomatis', 'Hemat daya', 'Seimbang', 'Performa', 'Kecepatan CPU', 'Sisa waktu', 'Waktu sampai penuh', 'Mengisi daya', 'Melepas daya', 'Penuh', 'Tidak tersedia di mesin ini' ],
ko => [ '전원', '전원 연결 시', '배터리 사용 시', '자동', '절전', '균형', '성능', 'CPU 속도', '남은 시간', '완충까지', '충전 중', '방전 중', '완충', '이 기기에서 사용할 수 없음' ],
it => [ 'Alimentazione', 'Alimentazione esterna', 'A batteria', 'Automatico', 'Risparmio energetico', 'Bilanciato', 'Prestazioni', 'Velocità CPU', 'Tempo rimasto', 'Tempo alla carica', 'In carica', 'In scarica', 'Piena', 'Non disponibile su questa macchina' ],
tr => [ 'Güç', 'Şebekede', 'Pilde', 'Otomatik', 'Güç tasarrufu', 'Dengeli', 'Performans', 'CPU hızı', 'Kalan süre', 'Doluma kalan süre', 'Şarj oluyor', 'Deşarj oluyor', 'Dolu', 'Bu makinede kullanılamıyor' ],
);
foreach my $code ( keys %power_app_labels ) {
	my %add;
	@add{@power_app_keys} = @{$power_app_labels{$code}};
	$catalog{$code} = { %{$catalog{$code} || {}}, %add };
}

# The Sound app's own labels. These are core labels on the app window, the
# start menu and the taskbar widget, so they are written in every interface
# language here rather than left to the English backfill. The sentences around
# them go through subs::ui and are translated on demand.
my @sound_keys = qw( sound sound_output sound_input sound_default sound_set_default
	sound_volume sound_mute sound_muted sound_speaker sound_microphone
	sound_no_devices sound_not_available sound_browser_default
	sound_profile sound_passive sound_quiet sound_silence );
my %sound_labels = (
en => [ 'Sound', 'Output', 'Input', 'Default', 'Set default', 'Volume', 'Mute', 'Muted', 'Speaker', 'Microphone', 'No devices found', 'Not available on this machine', 'Browser default', 'Sound profile', 'Passive', 'Quiet', 'Silence' ],
zh => [ '声音', '输出', '输入', '默认', '设为默认', '音量', '静音', '已静音', '扬声器', '麦克风', '未找到设备', '此机器不可用', '浏览器默认', '声音配置', '被动', '安静', '静默' ],
fr => [ 'Son', 'Sortie', 'Entrée', 'Par défaut', 'Définir par défaut', 'Volume', 'Couper le son', 'Son coupé', 'Haut-parleur', 'Microphone', 'Aucun appareil trouvé', 'Indisponible sur cette machine', 'Navigateur par défaut', 'Profil sonore', 'Passif', 'Calme', 'Silence' ],
es => [ 'Sonido', 'Salida', 'Entrada', 'Predeterminado', 'Establecer como predeterminado', 'Volumen', 'Silenciar', 'Silenciado', 'Altavoz', 'Micrófono', 'No se encontraron dispositivos', 'No disponible en esta máquina', 'Predeterminado del navegador', 'Perfil de sonido', 'Pasivo', 'Silencioso', 'Silencio' ],
de => [ 'Ton', 'Ausgabe', 'Eingabe', 'Standard', 'Als Standard festlegen', 'Lautstärke', 'Stummschalten', 'Stummgeschaltet', 'Lautsprecher', 'Mikrofon', 'Keine Geräte gefunden', 'Auf dieser Maschine nicht verfügbar', 'Browser-Standard', 'Tonprofil', 'Passiv', 'Leise', 'Stille' ],
pt => [ 'Som', 'Saída', 'Entrada', 'Padrão', 'Definir como padrão', 'Volume', 'Silenciar', 'Silenciado', 'Alto-falante', 'Microfone', 'Nenhum dispositivo encontrado', 'Indisponível nesta máquina', 'Padrão do navegador', 'Perfil de som', 'Passivo', 'Silencioso', 'Silêncio' ],
hi => [ 'ध्वनि', 'आउटपुट', 'इनपुट', 'डिफ़ॉल्ट', 'डिफ़ॉल्ट बनाएँ', 'वॉल्यूम', 'म्यूट', 'म्यूट किया गया', 'स्पीकर', 'माइक्रोफ़ोन', 'कोई डिवाइस नहीं मिला', 'इस मशीन पर उपलब्ध नहीं', 'ब्राउज़र डिफ़ॉल्ट', 'ध्वनि प्रोफ़ाइल', 'निष्क्रिय', 'शांत', 'मौन' ],
ar => [ 'الصوت', 'الإخراج', 'الإدخال', 'الافتراضي', 'تعيين كافتراضي', 'مستوى الصوت', 'كتم', 'مكتوم', 'مكبر الصوت', 'الميكروفون', 'لم يتم العثور على أجهزة', 'غير متاح على هذا الجهاز', 'افتراضي المتصفح', 'ملف الصوت', 'سلبي', 'هادئ', 'صمت' ],
bn => [ 'শব্দ', 'আউটপুট', 'ইনপুট', 'ডিফল্ট', 'ডিফল্ট সেট করুন', 'ভলিউম', 'মিউট', 'মিউট করা', 'স্পিকার', 'মাইক্রোফোন', 'কোনো ডিভাইস পাওয়া যায়নি', 'এই মেশিনে উপলব্ধ নয়', 'ব্রাউজার ডিফল্ট', 'সাউন্ড প্রোফাইল', 'নিষ্ক্রিয়', 'শান্ত', 'নীরবতা' ],
ru => [ 'Звук', 'Выход', 'Вход', 'По умолчанию', 'Сделать по умолчанию', 'Громкость', 'Без звука', 'Без звука', 'Динамик', 'Микрофон', 'Устройства не найдены', 'Недоступно на этой машине', 'По умолчанию в браузере', 'Звуковой профиль', 'Пассивный', 'Тихий', 'Тишина' ],
ja => [ 'サウンド', '出力', '入力', 'デフォルト', 'デフォルトに設定', '音量', 'ミュート', 'ミュート中', 'スピーカー', 'マイク', 'デバイスが見つかりません', 'このマシンでは利用できません', 'ブラウザのデフォルト', 'サウンドプロファイル', 'パッシブ', '静か', 'サイレンス' ],
pa => [ 'ਆਵਾਜ਼', 'ਆਉਟਪੁੱਟ', 'ਇਨਪੁੱਟ', 'ਡਿਫਾਲਟ', 'ਡਿਫਾਲਟ ਸੈੱਟ ਕਰੋ', 'ਵਾਲੀਅਮ', 'ਮਿਊਟ', 'ਮਿਊਟ ਕੀਤਾ', 'ਸਪੀਕਰ', 'ਮਾਈਕ੍ਰੋਫ਼ੋਨ', 'ਕੋਈ ਡਿਵਾਈਸ ਨਹੀਂ ਮਿਲੀ', 'ਇਸ ਮਸ਼ੀਨ ਤੇ ਉਪਲਬਧ ਨਹੀਂ', 'ਬ੍ਰਾਊਜ਼ਰ ਡਿਫਾਲਟ', 'ਆਵਾਜ਼ ਪ੍ਰੋਫ਼ਾਈਲ', 'ਪੈਸਿਵ', 'ਸ਼ਾਂਤ', 'ਖ਼ਾਮੋਸ਼ੀ' ],
id => [ 'Suara', 'Keluaran', 'Masukan', 'Bawaan', 'Jadikan bawaan', 'Volume', 'Bisukan', 'Dibisukan', 'Speaker', 'Mikrofon', 'Tidak ada perangkat ditemukan', 'Tidak tersedia di mesin ini', 'Bawaan browser', 'Profil suara', 'Pasif', 'Tenang', 'Senyap' ],
ko => [ '소리', '출력', '입력', '기본', '기본으로 설정', '볼륨', '음소거', '음소거됨', '스피커', '마이크', '장치를 찾을 수 없음', '이 기기에서 사용할 수 없음', '브라우저 기본', '사운드 프로필', '수동', '조용히', '무음' ],
it => [ 'Suono', 'Uscita', 'Ingresso', 'Predefinito', 'Imposta come predefinito', 'Volume', 'Muto', 'Muto', 'Altoparlante', 'Microfono', 'Nessun dispositivo trovato', 'Non disponibile su questa macchina', 'Predefinito del browser', 'Profilo audio', 'Passivo', 'Tranquillo', 'Silenzio' ],
tr => [ 'Ses', 'Çıkış', 'Giriş', 'Varsayılan', 'Varsayılan yap', 'Ses düzeyi', 'Sessize al', 'Sessiz', 'Hoparlör', 'Mikrofon', 'Cihaz bulunamadı', 'Bu makinede kullanılamıyor', 'Tarayıcı varsayılanı', 'Ses profili', 'Pasif', 'Sessiz', 'Sessizlik' ],
);
foreach my $code ( keys %sound_labels ) {
	my %add;
	@add{@sound_keys} = @{$sound_labels{$code}};
	$catalog{$code} = { %{$catalog{$code} || {}}, %add };
}

# Configure -> Plat -> QA. These are core labels on a settings panel, so they
# are written here in every interface language rather than left to the English
# backfill. The surrounding explanation is help text and goes through subs::ui.
my @qa_keys = qw( configure.qa_nightly configure.qa_nightly_device configure.qa_this_machine
	configure.qa_ready configure.qa_not_ready configure.qa_missing configure.qa_install
	configure.qa_check configure.qa_checking configure.qa_note_limit configure.qa_ux_model
	configure.qa_schedule configure.qa_suite_time configure.qa_ux_time
	configure.qa_coding_time configure.qa_save_times configure.qa_run_now
	configure.qa_effective configure.coding_push_repo configure.coding_app_push_repo
	configure.coding_push_effective configure.qa_off );
my %qa_labels = (
en => [ 'QA', 'Nightly machine', 'This machine (local)', 'Ready', 'Not ready', 'Missing', 'Install', 'Check again', 'Checking…', 'Notes per night', 'UX judgement model', 'Nightly schedule', 'QA suite time', 'UX run time', 'Coding night time', 'Save times', 'Run now', 'Scheduled', 'Coding push repo', 'Coding app push repo', 'Pushes to', 'Off' ],
zh => [ 'QA', '夜间运行的机器', '本机（本地）', '就绪', '未就绪', '缺少', '安装', '重新检查', '正在检查…', '每晚笔记数', 'UX 评判模型', '夜间时间表', 'QA 套件时间', 'UX 运行时间', '编程之夜时间', '保存时间', '立即运行', '已排定', '编程推送仓库', '应用推送仓库', '推送到', '关闭' ],
fr => [ 'QA', 'Machine de nuit', 'Cette machine (locale)', 'Prêt', 'Pas prêt', 'Manquant', 'Installer', 'Vérifier à nouveau', 'Vérification…', 'Notes par nuit', 'Modèle d\'évaluation UX', 'Planning nocturne', 'Heure de la suite QA', 'Heure du parcours UX', 'Heure de la nuit de codage', 'Enregistrer les heures', 'Exécuter maintenant', 'Planifié', 'Dépôt de poussée du code', 'Dépôt de poussée de l\'app', 'Pousse vers', 'Désactivé' ],
es => [ 'QA', 'Máquina nocturna', 'Esta máquina (local)', 'Listo', 'No listo', 'Falta', 'Instalar', 'Comprobar de nuevo', 'Comprobando…', 'Notas por noche', 'Modelo de evaluación UX', 'Horario nocturno', 'Hora de la suite QA', 'Hora del recorrido UX', 'Hora de la noche de código', 'Guardar horas', 'Ejecutar ahora', 'Programado', 'Repositorio de push del código', 'Repositorio de push de la app', 'Se envía a', 'Desactivado' ],
de => [ 'QA', 'Nachtmaschine', 'Diese Maschine (lokal)', 'Bereit', 'Nicht bereit', 'Fehlt', 'Installieren', 'Erneut prüfen', 'Prüfe…', 'Notizen pro Nacht', 'UX-Bewertungsmodell', 'Nachtplan', 'Zeit der QA-Suite', 'Zeit des UX-Laufs', 'Zeit der Codiernacht', 'Zeiten speichern', 'Jetzt ausführen', 'Geplant', 'Coding-Push-Repository', 'App-Push-Repository', 'Push an', 'Aus' ],
pt => [ 'QA', 'Máquina noturna', 'Esta máquina (local)', 'Pronto', 'Não pronto', 'Falta', 'Instalar', 'Verificar novamente', 'Verificando…', 'Notas por noite', 'Modelo de avaliação UX', 'Horário noturno', 'Hora da suíte QA', 'Hora da execução UX', 'Hora da noite de código', 'Guardar horas', 'Executar agora', 'Agendado', 'Repositório de push do código', 'Repositório de push do app', 'Envia para', 'Desligado' ],
hi => [ 'QA', 'रात्रि मशीन', 'यह मशीन (स्थानीय)', 'तैयार', 'तैयार नहीं', 'अनुपस्थित', 'इंस्टॉल करें', 'फिर जाँचें', 'जाँच हो रही है…', 'प्रति रात नोट्स', 'UX मूल्यांकन मॉडल', 'रात्रि समय-सारणी', 'QA सूट का समय', 'UX रन का समय', 'कोडिंग नाइट का समय', 'समय सहेजें', 'अभी चलाएँ', 'निर्धारित', 'कोडिंग पुश रिपॉज़िटरी', 'ऐप पुश रिपॉज़िटरी', 'यहाँ पुश होता है', 'बंद' ],
ar => [ 'QA', 'جهاز الفحص الليلي', 'هذا الجهاز (محلي)', 'جاهز', 'غير جاهز', 'مفقود', 'تثبيت', 'تحقق مرة أخرى', 'جارٍ التحقق…', 'ملاحظات في الليلة', 'نموذج تقييم UX', 'الجدول الليلي', 'وقت حزمة QA', 'وقت تشغيل UX', 'وقت ليلة البرمجة', 'حفظ الأوقات', 'شغّل الآن', 'مجدول', 'مستودع دفع الكود', 'مستودع دفع التطبيق', 'يُدفع إلى', 'إيقاف' ],
bn => [ 'QA', 'রাত্রিকালীন মেশিন', 'এই মেশিন (স্থানীয়)', 'প্রস্তুত', 'প্রস্তুত নয়', 'অনুপস্থিত', 'ইনস্টল করুন', 'আবার পরীক্ষা করুন', 'পরীক্ষা চলছে…', 'প্রতি রাতে নোট', 'UX মূল্যায়ন মডেল', 'রাত্রিকালীন সময়সূচি', 'QA স্যুটের সময়', 'UX চালনার সময়', 'কোডিং নাইটের সময়', 'সময় সংরক্ষণ করুন', 'এখন চালান', 'নির্ধারিত', 'কোডিং পুশ রিপোজিটরি', 'অ্যাপ পুশ রিপোজিটরি', 'এখানে পুশ হয়', 'বন্ধ' ],
ru => [ 'QA', 'Ночная машина', 'Эта машина (локально)', 'Готово', 'Не готово', 'Отсутствует', 'Установить', 'Проверить снова', 'Проверка…', 'Заметок за ночь', 'Модель оценки UX', 'Ночное расписание', 'Время набора QA', 'Время прогона UX', 'Время ночи кодинга', 'Сохранить время', 'Запустить сейчас', 'Запланировано', 'Репозиторий для push кода', 'Репозиторий для push приложения', 'Пушится в', 'Выкл.' ],
ja => [ 'QA', '夜間実行マシン', 'このマシン（ローカル）', '準備完了', '未準備', '不足', 'インストール', '再確認', '確認中…', '1晩のノート数', 'UX判定モデル', '夜間スケジュール', 'QAスイートの時刻', 'UX実行の時刻', 'コーディング夜間の時刻', '時刻を保存', '今すぐ実行', '予定時刻', 'コーディングのプッシュ先リポジトリ', 'アプリのプッシュ先リポジトリ', 'プッシュ先', 'オフ' ],
pa => [ 'QA', 'ਰਾਤ ਦੀ ਮਸ਼ੀਨ', 'ਇਹ ਮਸ਼ੀਨ (ਸਥਾਨਕ)', 'ਤਿਆਰ', 'ਤਿਆਰ ਨਹੀਂ', 'ਗੁੰਮ', 'ਇੰਸਟਾਲ ਕਰੋ', 'ਦੁਬਾਰਾ ਜਾਂਚੋ', 'ਜਾਂਚ ਹੋ ਰਹੀ ਹੈ…', 'ਹਰ ਰਾਤ ਨੋਟਸ', 'UX ਮੁਲਾਂਕਣ ਮਾਡਲ', 'ਰਾਤ ਦਾ ਸਮਾਂ-ਸਾਰਣੀ', 'QA ਸੂਟ ਦਾ ਸਮਾਂ', 'UX ਦੌੜ ਦਾ ਸਮਾਂ', 'ਕੋਡਿੰਗ ਨਾਈਟ ਦਾ ਸਮਾਂ', 'ਸਮੇਂ ਸੰਭਾਲੋ', 'ਹੁਣ ਚਲਾਓ', 'ਨਿਰਧਾਰਿਤ', 'ਕੋਡਿੰਗ ਪੁਸ਼ ਰਿਪੋ', 'ਐਪ ਪੁਸ਼ ਰਿਪੋ', 'ਇੱਥੇ ਪੁਸ਼ ਹੁੰਦਾ ਹੈ', 'ਬੰਦ' ],
id => [ 'QA', 'Mesin malam', 'Mesin ini (lokal)', 'Siap', 'Belum siap', 'Hilang', 'Pasang', 'Periksa lagi', 'Memeriksa…', 'Catatan per malam', 'Model penilaian UX', 'Jadwal malam', 'Waktu suite QA', 'Waktu jalannya UX', 'Waktu malam koding', 'Simpan waktu', 'Jalankan sekarang', 'Terjadwal', 'Repositori push kode', 'Repositori push aplikasi', 'Didorong ke', 'Mati' ],
ko => [ 'QA', '야간 실행 기기', '이 기기(로컬)', '준비됨', '준비 안 됨', '누락', '설치', '다시 확인', '확인 중…', '밤당 노트 수', 'UX 평가 모델', '야간 일정', 'QA 스위트 시간', 'UX 실행 시간', '코딩 야간 시간', '시간 저장', '지금 실행', '예약됨', '코딩 푸시 저장소', '앱 푸시 저장소', '푸시 대상', '꺼짐' ],
it => [ 'QA', 'Macchina notturna', 'Questa macchina (locale)', 'Pronto', 'Non pronto', 'Mancante', 'Installa', 'Controlla di nuovo', 'Controllo…', 'Note per notte', 'Modello di valutazione UX', 'Pianificazione notturna', 'Ora della suite QA', 'Ora dell\'esecuzione UX', 'Ora della notte di coding', 'Salva orari', 'Esegui ora', 'Pianificato', 'Repository di push del codice', 'Repository di push dell\'app', 'Esegue il push su', 'Spento' ],
tr => [ 'QA', 'Gece makinesi', 'Bu makine (yerel)', 'Hazır', 'Hazır değil', 'Eksik', 'Kur', 'Yeniden denetle', 'Denetleniyor…', 'Gece başına not', 'UX değerlendirme modeli', 'Gece programı', 'QA takımı saati', 'UX çalışma saati', 'Kodlama gecesi saati', 'Saatleri kaydet', 'Şimdi çalıştır', 'Planlandı', 'Kod gönderme deposu', 'Uygulama gönderme deposu', 'Gönderim hedefi', 'Kapalı' ],
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
