import 'dart:io';
import "package:path/path.dart" show join;
import 'dart:convert';
import 'package:image/image.dart';
import 'package:logging/logging.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const fileNameConfig = 'config.json';

void main() async {
  final configFile = File(fileNameConfig);
  if (!configFile.existsSync()) {
    throw 'Ненайден файл конфигурации config.json.';
  }
  final configText = configFile.readAsStringSync(); // файл конфигурации приложения
  final config = json.decode(configText); // конфигурация приложения

  final pathLogo = config["logo"]["path"]; // путь к логотипу
  final dirInput = config["fileSystem"]["dirInput"]; // директория для загрузки
  final dirOutput = config["fileSystem"]["dirOutput"]; // директория для выгрузки
  final pathLog = config['log']['path'] + config['log']['name']; // путь к файлу логов
  final MAX_HEIGHT = config["image"]["maxHeight"]; // максимальная высота
  final MAX_WIDTH = config["image"]["maxWidth"]; // максимальная ширина
  final SIZE_FACTOR = MAX_WIDTH / MAX_HEIGHT; // разница сторон

  // Инициализация логера.
  final fileLog = File(pathLog);
  fileLog.createSync(recursive: true);
  Logger.root.level = Level.ALL;
  Logger.root.onRecord.listen((record) {
    fileLog.writeAsStringSync('${record.level.name}: ${record.time}: ${record.message}\n', mode: FileMode.append);
  });
  final log = Logger('MyClassName');

  sqfliteFfiInit();
  final databaseFactory = databaseFactoryFfi;
  final db = await databaseFactory.openDatabase(join(Directory.current.path, 'data.sqlite'));
  await db.execute('CREATE TABLE if not exists files (inFile TEXT, outFile TEXT, birthtime integer, mtime integer)');

  // Проверить существование директорий и файлов.
  final directoryInput = new Directory(dirInput);
  if (!directoryInput.existsSync()) {
    log.warning('Неправильная директория получения файлов: $dirInput');
    throw 'Неправильная директория получения.';
  }
  final directoryOutput = new Directory(dirOutput);
  if (!directoryOutput.existsSync()) {
    log.warning('Неправильная директория назначения: $dirOutput');
    throw 'Неправильная директория назначения.';
  }

  final logoFile = File(pathLogo);
  if (!logoFile.existsSync()) {
    log.warning('Не найден файл водяного знака: $pathLogo');
    throw 'Не найден файл водяного знака.';
  }

  // Подготовить водяной знак.
  final watermarkOriginal = decodeImage(logoFile.readAsBytesSync());
  if (watermarkOriginal == null) {
    log.warning('Не удалось прочитать файл водяного знака: $pathLogo');
    throw 'Не удалось прочитать файл водяного знака.';
  }
  final watermark = adjustColor(watermarkOriginal, saturation: 100); // логотип

  for (var file in directoryInput.listSync(recursive: true)) {
    if (file is File) {
      final pathSrc = file.path;
      final pathOut = pathSrc.replaceAll(dirInput, dirOutput);

      final statSrc = FileStat.statSync(pathSrc);
      final result = await db.rawQuery('SELECT * FROM files where inFile=?', [pathSrc]);
      if (result.length > 0) {
        // Есть запись о конвертации.
        if (result.first['birthtime'] != statSrc.changed.microsecondsSinceEpoch || result.first['mtime'] != statSrc.modified.microsecondsSinceEpoch) {
          // Нужно обновить файл, был изменен.
          if (convertImage(MAX_HEIGHT, MAX_WIDTH, SIZE_FACTOR, pathSrc, pathOut, watermark)) {
            log.info('Обновлен файл $pathSrc в $pathOut');
            final record = {
              'inFile': pathSrc,
              'outFile': pathOut,
              'birthtime': statSrc.changed.microsecondsSinceEpoch,
              'mtime': statSrc.modified.microsecondsSinceEpoch
            };
            await db.update('files', record, where: "inFile = ?", whereArgs: [pathSrc]);
          }
        }
      } else {
        if (convertImage(MAX_HEIGHT, MAX_WIDTH, SIZE_FACTOR, pathSrc, pathOut, watermark)) {
          log.info('Конвертирован файл $pathSrc в $pathOut');
          await db.insert('files', <String, Object>{
            'inFile': pathSrc,
            'outFile': pathOut,
            'birthtime': statSrc.changed.microsecondsSinceEpoch,
            'mtime': statSrc.modified.microsecondsSinceEpoch
          });
        }
      }
    }
  }
  await db.close();
}

bool convertImage(MAX_HEIGHT, MAX_WIDTH, SIZE_FACTOR, String pathSrc, String pathOut, Image watermark) {
  final Image? imageSrc = decodeImage(File(pathSrc).readAsBytesSync());
  if (imageSrc == null) return false;
  Image imageOut;
  if (imageSrc.width / imageSrc.height > SIZE_FACTOR) {
    imageOut = copyResize(imageSrc, width: MAX_WIDTH);
  } else {
    imageOut = copyResize(imageSrc, height: MAX_HEIGHT);
  }
  imageOut = drawImage(imageOut, watermark, srcW: imageOut.width, srcH: imageOut.height);
  final fileOut = File(pathOut);
  fileOut.createSync(recursive: true);
  fileOut.writeAsBytesSync(encodeJpg(imageOut));
  return true;
}
