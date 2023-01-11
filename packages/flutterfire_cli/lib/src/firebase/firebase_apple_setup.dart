import 'dart:convert';
import 'dart:io';

import 'package:cli_util/cli_logging.dart';
import 'package:path/path.dart' as path;

import '../common/strings.dart';
import '../common/utils.dart';
import '../firebase/firebase_options.dart';

import '../flutter_app.dart';

// Use for both macOS & iOS
class FirebaseAppleSetup {
  FirebaseAppleSetup(
    this.platformOptions,
    this.flutterApp,
    this.fullPathToServiceFile,
    this.relativePathToServiceFile,
    this.logger,
    this.generateDebugSymbolScript,
    this.scheme,
    this.target,
    this.platform,
  );
  // Either "iOS" or "macOS"
  final String platform;
  final FlutterApp? flutterApp;
  final FirebaseOptions platformOptions;
  String? fullPathToServiceFile;
  String? relativePathToServiceFile;
  final Logger logger;
  final bool? generateDebugSymbolScript;
// This allows us to update to the required "GoogleService-Info.plist" file name for iOS target or scheme writes.
  String? updatedServiceFilePath;
  String? scheme;
  String? target;

  String get xcodeProjFilePath {
    return path.join(flutterApp!.iosDirectory.path, 'Runner.xcodeproj');
  }

  Future<void> _addFlutterFireDebugSymbolsScript(
    String xcodeProjFilePath,
    Logger logger, {
    String target = 'Runner',
  }) async {
    final paths = _addPathToExecutablesForDebugScript();
    if (paths != null) {
      final debugSymbolScript = await Process.run('ruby', [
        '-e',
        _debugSymbolsScript(
          xcodeProjFilePath,
          target,
          paths,
        ),
      ]);

      if (debugSymbolScript.exitCode != 0) {
        throw Exception(debugSymbolScript.stderr);
      }

      if (debugSymbolScript.stdout != null) {
        logger.stdout(debugSymbolScript.stdout as String);
      }
    }
  }

//TODO - need to find a way to fix path so it isn't dependent on environment
  String _debugSymbolsScript(
    String xcodeProjFilePath,
    // Always "Runner" for "scheme" setup
    String target,
    String pathsToExecutables,
  ) {
    return '''
require 'xcodeproj'
xcodeFile='$xcodeProjFilePath'
runScriptName='$runScriptName'
project = Xcodeproj::Project.open(xcodeFile)


# multi line argument for bash script
bashScript = %q(
#!/bin/bash
PATH=\${PATH}:$pathsToExecutables

flutterfire upload-crashlytics-symbols --uploadSymbolsScriptPath=\$PODS_ROOT/FirebaseCrashlytics/upload-symbols --debugSymbolsPath=\${DWARF_DSYM_FOLDER_PATH}/\${DWARF_DSYM_FILE_NAME} --infoPlistPath=\${SRCROOT}/\${BUILT_PRODUCTS_DIR}/\${INFOPLIST_PATH} --scheme=\${CONFIGURATION} --iosProjectPath=\${SRCROOT}
)

for target in project.targets 
  if (target.name == '$target')
    phase = target.shell_script_build_phases().find do |item|
      if defined? item && item.name
        item.name == runScriptName
      end
    end

    if (phase.nil?)
        phase = target.new_shell_script_build_phase(runScriptName)
        phase.shell_script = bashScript
        project.save() 
    else
        \$stdout.write "Shell script already exists for running `flutterfire upload-crashlytics-symbols`, skipping..."
        exit(0)
    end
  end  
end
''';
  }

  final runScriptName = 'FlutterFire: "flutterfire upload-crashlytics-symbols"';

// Constants for firebase.json properties
  final projectIdName = 'projectId';
  final appIdName = 'projectId';
  final uploadDebugSymbolsName = 'uploadDebugSymbols';

  Future<void> _updateFirebaseJsonFileScheme(
    FlutterApp flutterApp,
    String appId,
    String projectId,
    bool debugSymbolScript,
    String scheme,
  ) async {
    final file = File('${flutterApp.package.path}/firebase.json');

    final fileAsString = await file.readAsString();

    final map = jsonDecode(fileAsString) as Map;

    final flutterConfig = map['flutter'] as Map?;
    final platform = flutterConfig?['platforms'] as Map?;
    final iosConfig = platform?['ios'] as Map?;

    final schemeConfigurations = iosConfig?['schemes'] as Map?;
    final schemeConfig = schemeConfigurations?[scheme] as Map?;

    schemeConfig?[projectIdName] = projectId;
    schemeConfig?[appIdName] = appId;
    schemeConfig?[uploadDebugSymbolsName] = debugSymbolScript;

    final mapJson = json.encode(map);

    file.writeAsStringSync(mapJson);
  }

  Future<void> _updateFirebaseJsonFileTarget(
    FlutterApp flutterApp,
    String appId,
    String projectId,
    bool debugSymbolScript,
    String target,
  ) async {
    final file = File('${flutterApp.package.path}/firebase.json');

    final fileAsString = await file.readAsString();

    final map = jsonDecode(fileAsString) as Map;

    final flutterConfig = map['flutter'] as Map?;
    final platform = flutterConfig?['platforms'] as Map?;
    final iosConfig = platform?['ios'] as Map?;

    final targetConfigurations = iosConfig?['targets'] as Map?;
    final targetConfig = targetConfigurations?[target] as Map?;

    targetConfig?[projectIdName] = projectId;
    targetConfig?[appIdName] = appId;
    targetConfig?[uploadDebugSymbolsName] = debugSymbolScript;

    final mapJson = json.encode(map);

    file.writeAsStringSync(mapJson);
  }

  bool _shouldRunUploadDebugSymbolScript(
    bool? generateDebugSymbolScript,
    Logger logger,
  ) {
    // ignore: use_if_null_to_convert_nulls_to_bools
    if (generateDebugSymbolScript == true) {
      return true;
    } else if (generateDebugSymbolScript == false) {
      return false;
    } else {
      final addSymbolScript = promptBool(
        "Do you want an '$runScriptName' adding to the build phases of your $platform project?",
      );
      if (addSymbolScript == true) {
        return true;
      } else {
        logger.stdout(
          logSkippingDebugSymbolScript,
        );
        return false;
      }
    }
  }

  Future<void> _updateFirebaseJsonAndDebugSymbolScript({
    String? scheme,
    String? target,
  }) async {
    final runDebugSymbolScript = _shouldRunUploadDebugSymbolScript(
      generateDebugSymbolScript,
      logger,
    );

    if (runDebugSymbolScript) {
      await _addFlutterFireDebugSymbolsScript(
        xcodeProjFilePath,
        logger,
      );
    }

    if (scheme != null) {
      await _updateFirebaseJsonFileScheme(
        flutterApp!,
        platformOptions.appId,
        platformOptions.projectId,
        runDebugSymbolScript,
        scheme,
      );
    } else if (target != null) {
      // Chosen Target or default
      await _updateFirebaseJsonFileTarget(
        flutterApp!,
        platformOptions.appId,
        platformOptions.projectId,
        runDebugSymbolScript,
        target,
      );
    } else {
      throw Exception(
          'Ensure that either a "target" or a "scheme" has been selected for $platform configuration.');
    }
  }

  String? _addPathToExecutablesForDebugScript() {
    final envVars = Platform.environment;
    final paths = envVars['PATH'];
    if (paths != null) {
      final array = paths.split(':');

      final pathsToAddToScript = array.where((path) {
        if (path.contains('dart-sdk') ||
            path.contains('flutter') ||
            path.contains('.pub-cache')) {
          return true;
        }
        return false;
      });

      return pathsToAddToScript.join(':');
    } else {
      logger.stdout(
        noPathVariableFound,
      );
      return null;
    }
  }

  Future<void> apply() async {
    final googleServiceInfoFile = path.join(
      flutterApp!.iosDirectory.path,
      'Runner',
      platformOptions.optionsSourceFileName,
    );

    File file;

    if (scheme != null && fullPathToServiceFile == null) {
      // if the user has selected a  scheme but no "[ios-macos]-out" argument, they need to specify the location of "GoogleService-Info.plist" so it can be used at build time.
      // No need to do the same for target as it is included with bundle resources and included in Runner directory
      final pathToServiceFile = promptInput(
        'Enter a path for your $platform "GoogleService-Info.plist" ("${platform.toLowerCase()}-out" argument.) file in your Flutter project. It is required if you set "${platform.toLowerCase()}-scheme" argument. Example input: ${platform.toLowerCase()}/dev',
        validator: (String x) {
          if (RegExp(r'^(?![#\/.])(?!.*[#\/.]$).*').hasMatch(x) &&
              !path.basename(x).contains('.')) {
            return true;
          } else {
            return 'Do not start or end path with a forward slash, nor specify the filename. Example: ${platform.toLowerCase()}/dev';
          }
        },
      );

      fullPathToServiceFile =
          '${flutterApp!.package.path}/$pathToServiceFile/${platformOptions.optionsSourceFileName}';

      relativePathToServiceFile =
          '$pathToServiceFile/${platformOptions.optionsSourceFileName}';

      await Directory(path.dirname(fullPathToServiceFile!))
          .create(recursive: true);

      file = File(fullPathToServiceFile!);
      // If "fullPathToServiceFile" exists, we use a different configuration from Runner/GoogleService-Info.plist setup
    } else if (fullPathToServiceFile != null) {
      final googleServiceFileName = path.basename(relativePathToServiceFile!);

      if (googleServiceFileName != platformOptions.optionsSourceFileName) {
        final response = promptBool(
          'The file name must be "${platformOptions.optionsSourceFileName}" if you\'re bundling with your $platform target or scheme. Do you want to change filename to "${platformOptions.optionsSourceFileName}"?',
        );

        // Change filename to "GoogleService-Info.plist" if user wants to, it is required for target or scheme setup
        if (response == true) {
          relativePathToServiceFile = path.join(
            path.dirname(relativePathToServiceFile!),
            platformOptions.optionsSourceFileName,
          );

          fullPathToServiceFile =
              '${flutterApp!.package.path}${relativePathToServiceFile!}';
        }
      }
      // Create new directory for file output if it doesn't currently exist
      await Directory(path.dirname(fullPathToServiceFile!))
          .create(recursive: true);

      file = File(fullPathToServiceFile!);
    } else {
      file = File(googleServiceInfoFile);
    }

    if (!file.existsSync()) {
      await file.writeAsString(platformOptions.optionsSourceContent);
    }

    if (Platform.isMacOS) {
      if (fullPathToServiceFile != null) {
        if (scheme != null) {
          final schemes = await findSchemesAvailable(xcodeProjFilePath);

          final schemeExists = schemes.contains(scheme);

          if (schemeExists) {
            await writeSchemeScriptToProject(
              xcodeProjFilePath,
              relativePathToServiceFile!,
              scheme!,
              logger,
            );
            await _updateFirebaseJsonAndDebugSymbolScript(scheme: scheme);
          } else {
            throw MissingFromXcodeProjectException(
              platform,
              'scheme',
              scheme!,
              schemes,
            );
          }
        } else if (target != null) {
          final targets = await findTargetsAvailable(xcodeProjFilePath);

          final targetExists = targets.contains(target);

          if (targetExists) {
            await writeToTargetProject(
              xcodeProjFilePath,
              fullPathToServiceFile!,
              target!,
            );

            await _updateFirebaseJsonAndDebugSymbolScript(target: target);
          } else {
            throw MissingFromXcodeProjectException(
              platform,
              'target',
              target!,
              targets,
            );
          }
        } else {
          // We need to prompt user whether they want a scheme configured, target configured or to simply write to the path provided
          final fileName = path.basename(fullPathToServiceFile!);
          final response = promptSelect(
            'Would you like your $platform $fileName to be associated with your $platform Scheme or Target (use arrow keys & space to select)?',
            [
              'Scheme',
              'Target',
              'No, I want to write the file to the path I chose'
            ],
          );

          // Add to scheme
          if (response == 0) {
            final schemes = await findSchemesAvailable(xcodeProjFilePath);

            final response = promptSelect(
              'Which scheme would you like your $platform $fileName to be included within your $platform app bundle?',
              schemes,
            );
            await writeSchemeScriptToProject(
              xcodeProjFilePath,
              relativePathToServiceFile!,
              schemes[response],
              logger,
            );
            await _updateFirebaseJsonAndDebugSymbolScript(
              scheme: schemes[response],
            );

            // Add to target
          } else if (response == 1) {
            final targets = await findTargetsAvailable(xcodeProjFilePath);

            final response = promptSelect(
              'Which target would you like your $platform $fileName to be included within your $platform app bundle?',
              targets,
            );
            await writeToTargetProject(
              xcodeProjFilePath,
              fullPathToServiceFile!,
              targets[response],
            );
            await _updateFirebaseJsonAndDebugSymbolScript(
              target: targets[response],
            );
          }
        }
      } else {
        // Continue to write file to Runner/GoogleService-Info.plist if no "iosServiceFilePath" is provided
        final rubyScript = addServiceFileToRunnerScript(
          googleServiceInfoFile,
          xcodeProjFilePath,
        );

        final result = await Process.run('ruby', [
          '-e',
          rubyScript,
        ]);

        if (result.exitCode != 0) {
          throw Exception(result.stderr);
        }
        // Update "Runner", default target
        await _updateFirebaseJsonAndDebugSymbolScript(target: 'Runner');
      }
    }
  }
}
