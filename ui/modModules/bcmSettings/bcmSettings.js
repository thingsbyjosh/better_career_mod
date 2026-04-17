'use strict'

angular.module('beamng.stuff')
.controller('BCMSettingsController', ['$scope', '$state', function($scope, $state) {

  // Settings model (synced with Lua)
  $scope.settings = {
    timeSpeed: 'normal',
    skipNights: false,
    nightDuration: 'normal',
    weatherEnabled: true,
    seasonLock: 'auto',
    language: 'en',
    policeEnabled: true,
    policeCount: 3,
    policeAdditive: false,
    policeSpawnMode: 'flexible',
    policeFlexMin: 1,
    policeFlexMax: 4,
    policePresenceCycle: 45,
    pursuitHudEnabled: true,
    turboEncabulator: false,
    planexTimeMultiplier: 1.0,
    debugMode: false,
    contextualTutorialsDisabled: false
  };

  // Tutorial state
  $scope.hasActiveSave = false;
  $scope.resetTutorialsConfirming = false;

  // Police count options for picker buttons
  $scope.policeCountOptions = [1, 2, 3, 4, 5, 6];

  // Set police count (integer setting)
  $scope.setPoliceCount = function(value) {
    if ($scope.settings.policeCount === value) return;
    $scope.settings.policeCount = value;
    bngApi.engineLua("extensions.bcm_settings.setSetting('policeCount', " + value + ")");
  };

  // Set police spawn mode (flexible/static)
  $scope.setSpawnMode = function(value) {
    if ($scope.settings.policeSpawnMode === value) return;
    $scope.settings.policeSpawnMode = value;
    bngApi.engineLua("extensions.bcm_settings.setSetting('policeSpawnMode', '" + value + "')");
  };

  // Set presence cycle interval
  $scope.setPresenceCycle = function(value) {
    if ($scope.settings.policePresenceCycle === value) return;
    $scope.settings.policePresenceCycle = value;
    bngApi.engineLua("extensions.bcm_settings.setSetting('policePresenceCycle', " + value + ")");
  };

  // Set police flex min/max (integer sliders)
  $scope.setFlexValue = function(key, value) {
    value = parseInt(value);
    if ($scope.settings[key] === value) return;

    // Enforce min < max constraint
    if (key === 'policeFlexMin' && value >= $scope.settings.policeFlexMax) {
      value = $scope.settings.policeFlexMax - 1;
    }
    if (key === 'policeFlexMax' && value <= $scope.settings.policeFlexMin) {
      value = $scope.settings.policeFlexMin + 1;
    }

    $scope.settings[key] = value;
    bngApi.engineLua("extensions.bcm_settings.setSetting('" + key + "', " + value + ")");
  };

  // Loading state
  $scope.loaded = false;

  // Load all settings from Lua on init
  $scope.loadAllSettings = function() {
    bngApi.engineLua("extensions.bcm_settings.getAllSettings()", function(result) {
      $scope.$apply(function() {
        if (result) {
          // Merge Lua settings into scope
          for (var key in result) {
            if ($scope.settings.hasOwnProperty(key)) {
              $scope.settings[key] = result[key];
            }
          }
          // Clamp flex values to valid range (may be corrupted from old tutorial approach)
          if ($scope.settings.policeFlexMin < 0) $scope.settings.policeFlexMin = 0;
          if ($scope.settings.policeFlexMax < 2) $scope.settings.policeFlexMax = 4;
        }
        $scope.loaded = true;
      });
    });

    // Load tutorial-specific state from bcm_tutorial extension
    bngApi.engineLua("extensions.bcm_tutorial.hasActiveSave()", function(result) {
      $scope.$apply(function() { $scope.hasActiveSave = !!result; });
    });

    bngApi.engineLua("extensions.bcm_tutorial.areContextualTutorialsDisabled()", function(result) {
      $scope.$apply(function() { $scope.settings.contextualTutorialsDisabled = !!result; });
    });
  };

  // Toggle contextual tutorials on/off
  $scope.toggleContextualTutorials = function() {
    $scope.settings.contextualTutorialsDisabled = !$scope.settings.contextualTutorialsDisabled;
    if ($scope.settings.contextualTutorialsDisabled) {
      bngApi.engineLua("extensions.bcm_tutorial.disableAllContextualTutorials()");
    } else {
      bngApi.engineLua("extensions.bcm_tutorial.enableContextualTutorials()");
    }
  };

  // Reset tutorials — two-step confirmation flow
  $scope.resetTutorials = function() {
    if (!$scope.hasActiveSave) return;
    $scope.resetTutorialsConfirming = true;
  };

  $scope.confirmResetTutorials = function() {
    $scope.resetTutorialsConfirming = false;
    bngApi.engineLua("extensions.bcm_tutorial.resetContextualTutorials()");
    $scope.settings.contextualTutorialsDisabled = false;
  };

  $scope.cancelResetTutorials = function() {
    $scope.resetTutorialsConfirming = false;
  };

  // Full tutorial reset (linear tutorial) — two-step confirmation flow
  $scope.resetFullTutorialConfirming = false;

  $scope.resetFullTutorial = function() {
    if (!$scope.hasActiveSave) return;
    if ($scope.resetFullTutorialConfirming) {
      $scope.resetFullTutorialConfirming = false;
      bngApi.engineLua("extensions.bcm_tutorial.resetFullTutorial()");
    } else {
      $scope.resetFullTutorialConfirming = true;
    }
  };

  $scope.cancelResetFullTutorial = function() {
    $scope.resetFullTutorialConfirming = false;
  };

  // Set a preset-type setting (timeSpeed, nightDuration, seasonLock)
  $scope.setPreset = function(key, value) {
    if ($scope.settings[key] === value) return;  // No change
    $scope.settings[key] = value;
    // Strings need quoting in Lua call
    bngApi.engineLua("extensions.bcm_settings.setSetting('" + key + "', '" + value + "')");
  };

  // Set a boolean setting to a specific value (used by ng-change on checkboxes with ng-model)
  $scope.setBoolSetting = function(key, value) {
    bngApi.engineLua("extensions.bcm_settings.setSetting('" + key + "', " + !!value + ")");
  };

  // Toggle a boolean setting (weatherEnabled, turboEncabulator)
  $scope.toggleSetting = function(key) {
    $scope.settings[key] = !$scope.settings[key];
    bngApi.engineLua("extensions.bcm_settings.setSetting('" + key + "', " + $scope.settings[key] + ")");
  };

  // Slider change handler (e.g. planexTimeMultiplier)
  $scope.onSliderChange = function(key, value) {
    bngApi.engineLua("extensions.bcm_settings.setSetting('" + key + "', " + value + ")");
  };

  // Navigate back to main menu
  $scope.goBack = function() {
    $state.go('menu.mainmenu');
  };

  // Initialize
  $scope.loadAllSettings();
}])

export default angular.module('bcmSettings', ['ui.router'])

.config(['$stateProvider', function($stateProvider) {
  $stateProvider.state('menu.bcmSettings', {
    url: '/bcmSettings',
    templateUrl: '/ui/modModules/bcmSettings/bcmSettings.html',
    controller: 'BCMSettingsController',
  })
}])

.run(['$rootScope', function($rootScope) {
  function addBCMSettingsButton() {
    if (window.bridge && window.bridge.events) {
      try {
        window.bridge.events.on("MainMenuButtons", function(addButton) {
          if (typeof addButton === 'function') {
            addButton({
              icon: '/ui/modModules/bcmSettings/icons/bcm_icon.svg',
              targetState: 'menu.bcmSettings',
              translateid: 'BCM Settings'
            })
          }
        })
      } catch (e) {
        console.error('BCMSettings: Error registering bridge event listener:', e)
      }
    }
  }

  addBCMSettingsButton()
}])
