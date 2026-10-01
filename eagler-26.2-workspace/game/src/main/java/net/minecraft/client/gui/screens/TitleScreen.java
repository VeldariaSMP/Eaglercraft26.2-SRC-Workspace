package net.minecraft.client.gui.screens;

import com.mojang.authlib.minecraft.BanDetails;
import com.mojang.logging.LogUtils;
import com.mojang.realmsclient.RealmsMainScreen;
import java.io.IOException;
import java.util.Objects;
import net.minecraft.SharedConstants;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.CommonButtons;
import net.minecraft.client.gui.components.LogoRenderer;
import net.minecraft.client.gui.components.PlainTextButton;
import net.minecraft.client.gui.components.SplashRenderer;
import net.minecraft.client.gui.components.SpriteIconButton;
import net.minecraft.client.gui.components.Tooltip;
import net.minecraft.client.gui.components.toasts.SystemToast;
import net.minecraft.client.gui.screens.multiplayer.JoinMultiplayerScreen;
import net.minecraft.client.gui.screens.multiplayer.SafetyScreen;
import net.minecraft.client.gui.screens.options.AccessibilityOptionsScreen;
import net.minecraft.client.gui.screens.options.LanguageSelectScreen;
import net.minecraft.client.gui.screens.options.OptionsScreen;
import net.minecraft.client.gui.screens.worldselection.CreateWorldScreen;
import net.minecraft.client.gui.screens.worldselection.SelectWorldScreen;
import net.minecraft.client.quickplay.QuickPlay;
import net.minecraft.client.renderer.Panorama;
import net.minecraft.client.renderer.texture.TextureManager;
import net.minecraft.client.resources.language.I18n;
import net.minecraft.network.chat.CommonComponents;
import net.minecraft.network.chat.Component;
import net.minecraft.server.MinecraftServer;
import net.minecraft.util.ARGB;
import net.minecraft.util.Mth;
import net.minecraft.util.Util;
import net.minecraft.world.level.levelgen.WorldOptions;
import net.minecraft.world.level.levelgen.presets.WorldPresets;
import net.minecraft.world.level.storage.LevelStorageSource;
import org.jspecify.annotations.Nullable;
import org.slf4j.Logger;

public class TitleScreen extends Screen {
   private static final Logger LOGGER = LogUtils.getLogger();
   private static final Component TITLE = Component.translatable("narrator.screen.title");
   private static final Component COPYRIGHT_TEXT = Component.translatable("title.credits");
   private static final String DEMO_LEVEL_ID = "Demo_World";
   private @Nullable SplashRenderer splash;
   private boolean fading;
   private long fadeInStart;
   private final LogoRenderer logoRenderer;

   public TitleScreen() {
      this(false);
   }

   public TitleScreen(final boolean fading) {
      this(fading, null);
   }

   public TitleScreen(final boolean fading, final @Nullable LogoRenderer logoRenderer) {
      super(TITLE);
      this.fading = fading;
      this.logoRenderer = Objects.requireNonNullElseGet(logoRenderer, () -> new LogoRenderer(false));
      this.minecraft.gameRenderer.panorama().startSpin();
   }

   public static void registerTextures(final TextureManager textureManager) {
      textureManager.registerForNextReload(LogoRenderer.MINECRAFT_LOGO);
      textureManager.registerForNextReload(LogoRenderer.MINECRAFT_EDITION);
      textureManager.registerForNextReload(Panorama.PANORAMA_OVERLAY);
   }

   @Override
   public boolean isPauseScreen() {
      return false;
   }

   @Override
   public boolean shouldCloseOnEsc() {
      return false;
   }

   @Override
   protected void init() {
      if (this.splash == null) {
         this.splash = this.minecraft.gui.splashManager().getSplash();
      }

      int copyrightWidth = this.font.width(COPYRIGHT_TEXT);
      int copyrightX = this.width - copyrightWidth - 2;
      int spacing = 24;
      int topPos = this.height / 4 + 48;

      if (this.minecraft.isDemo()) {
         topPos = this.createDemoMenuOptions(topPos, spacing);
      } else {
         topPos = this.createNormalMenuOptions(topPos, spacing);
      }

      // 下段: 言語 | Settings | Edit Profile | アクセシビリティ
      topPos += spacing;
      int iconSize = 20;
      int midWidth = 98;
      int gap = 4;
      int totalWidth = iconSize + gap + midWidth + gap + midWidth + gap + iconSize;
      int x = this.width / 2 - totalWidth / 2;

      SpriteIconButton language = this.addRenderableWidget(
         CommonButtons.language(
            iconSize,
            btn -> this.minecraft.gui.setScreen(
               new LanguageSelectScreen(this, this.minecraft.options, this.minecraft.getLanguageManager())
            ),
            true
         )
      );
      language.setPosition(x, topPos);
      x += iconSize + gap;

      this.addRenderableWidget(
         Button.builder(
               Component.translatable("menu.options"),
               btn -> this.minecraft.gui.setScreen(new OptionsScreen(this, this.minecraft.options, false))
            )
            .bounds(x, topPos, midWidth, 20)
            .build()
      );
      x += midWidth + gap;

      // Account = Eagler Edit Profile
      if (!this.minecraft.isDemo()) {
         this.addRenderableWidget(
            Button.builder(
                  Component.literal("Edit Profile"),
                  btn -> this.minecraft.gui.setScreen(
                     new net.lax1dude.eaglercraft.v1_8.profile.EaglerProfileScreen26(this)
                  )
               )
               .bounds(x, topPos, midWidth, 20)
               .build()
         );
      } else {
         // デモ時は Profile の代わりに空白相当の余白を維持したくなければ
         // midWidth 分スキップ
      }
      x += midWidth + gap;

      SpriteIconButton accessibility = this.addRenderableWidget(
         CommonButtons.accessibility(
            iconSize,
            btn -> this.minecraft.gui.setScreen(new AccessibilityOptionsScreen(this, this.minecraft.options)),
            true
         )
      );
      accessibility.setPosition(x, topPos);

      // Quit / Credits（Eagler Hosted 時は Credits）
      topPos += spacing;
      boolean eaglerHosted = net.lax1dude.eaglercraft.v1_8.minecraft.EaglerHosted.isActive();
      this.addRenderableWidget(
         Button.builder(
               eaglerHosted
                  ? Component.translatableWithFallback("menu.credits", "Credits")
                  : Component.translatable("menu.quit"),
               btn -> {
                  if (eaglerHosted) {
                     this.minecraft.gui.setScreen(new EaglerCreditsScreen(this));
                  } else {
                     this.minecraft.stop();
                  }
               }
            )
            .bounds(this.width / 2 - 100, topPos, 200, 20)
            .build()
      );

      this.addRenderableWidget(
         new PlainTextButton(
            copyrightX,
            this.height - 10,
            copyrightWidth,
            10,
            COPYRIGHT_TEXT,
            btn -> this.minecraft.gui.setScreen(new CreditsAndAttributionScreen(this)),
            this.font
         )
      );

      String startupServer = this.minecraft.gui.screen() == this ? pendingStartupServer() : null;
      if (startupServer != null) {
         this.minecraft.execute(() -> {
            if (this.minecraft.gui.screen() == this && consumeStartupServer(startupServer)) {
               QuickPlay.connectStartupServer(this.minecraft, this, startupServer);
            }
         });
      } else if (!autoTestFired && net.lax1dude.eaglercraft.v1_8.internal.PlatformBootSignal.autoTestSp()) {
         autoTestFired = true;
         net.minecraft.client.gui.screens.worldselection.CreateWorldScreen.openFresh(this.minecraft, () -> {});
      }
   }

   private static boolean autoTestFired = false;
   private static boolean startupServerLoaded = false;
   private static boolean startupServerConsumed = false;
   private static @Nullable String startupServerPending = null;

   private static @Nullable String pendingStartupServer() {
      if (startupServerConsumed) {
         return null;
      }
      if (!startupServerLoaded) {
         startupServerLoaded = true;
         String value = net.lax1dude.eaglercraft.v1_8.EagRuntime.getConfiguration().getServerToJoin();
         startupServerPending = value == null || value.isBlank() ? null : value.trim();
      }
      return startupServerPending;
   }

   private static boolean consumeStartupServer(final String expected) {
      if (startupServerConsumed || startupServerPending == null || !startupServerPending.equals(expected)) {
         return false;
      }
      startupServerConsumed = true;
      startupServerPending = null;
      return true;
   }

   private int createNormalMenuOptions(int topPos, final int spacing) {
      Button singleplayerButton = this.addRenderableWidget(
         Button.builder(Component.translatable("menu.singleplayer"), var1 -> {
               if (net.lax1dude.eaglercraft.v1_8.minecraft.EaglerHosted.isActive()) {
                  net.lax1dude.eaglercraft.v1_8.mesh.MeshWorkerRuntime.prewarm();
                  net.lax1dude.eaglercraft.v1_8.sp.SingleplayerServerController26.prewarmServerWorker();
               }
               if (net.lax1dude.eaglercraft.v1_8.minecraft.EaglerHosted.isActive()
                     && net.lax1dude.eaglercraft.v1_8.sp.internal.ClientPlatformSingleplayer.isServerWorkerModeRequested()
                     && net.lax1dude.eaglercraft.v1_8.sp.SingleplayerServerController26.getState()
                        != net.lax1dude.eaglercraft.v1_8.sp.SingleplayerServerController26.STATE_WORKER_IDLE) {
                  this.minecraft.gui.setScreen(
                     new net.lax1dude.eaglercraft.v1_8.sp.gui.EaglerIntegratedServerStartupScreen(this)
                  );
               } else {
                  this.minecraft.gui.setScreen(new SelectWorldScreen(this));
               }
            })
            .bounds(this.width / 2 - 100, topPos, 200, 20)
            .build()
      );

      if (SharedConstants.IS_RUNNING_IN_IDE) {
         this.addRenderableWidget(
            Button.builder(
                  Component.literal("TW"),
                  var1 -> CreateWorldScreen.testWorld(this.minecraft, () -> this.minecraft.gui.setScreen(this))
               )
               .bounds(singleplayerButton.getX() + singleplayerButton.getWidth() + 2, topPos, 20, 20)
               .build()
         );
      }

      Component multiplayerDisabledReason = this.getMultiplayerDisabledReason();
      boolean multiplayerAllowed = multiplayerDisabledReason == null;
      Tooltip tooltip = multiplayerDisabledReason != null ? Tooltip.create(multiplayerDisabledReason) : null;

      // Multiplayer
      topPos += spacing;
      this.addRenderableWidget(
         Button.builder(Component.translatable("menu.multiplayer"), button -> {
               if (net.lax1dude.eaglercraft.v1_8.minecraft.EaglerHosted.isActive()) {
                  net.lax1dude.eaglercraft.v1_8.sp.SingleplayerServerController26.prepareForRemoteMultiplayer();
               }
               Screen screen = this.minecraft.options.skipMultiplayerWarning
                  ? new JoinMultiplayerScreen(this)
                  : new SafetyScreen(this);
               this.minecraft.gui.setScreen(screen);
            })
            .bounds(this.width / 2 - 100, topPos, 200, 20)
            .tooltip(tooltip)
            .build()
      ).active = multiplayerAllowed;

      // Minecraft Realms（遷移のみ）
      topPos += spacing;
      this.addRenderableWidget(
         Button.builder(
               Component.translatable("menu.online"),
               btn -> this.minecraft.gui.setScreen(new RealmsMainScreen(this))
            )
            .bounds(this.width / 2 - 100, topPos, 200, 20)
            .tooltip(tooltip)
            .build()
      ).active = multiplayerAllowed;

      return topPos;
   }

   private @Nullable Component getMultiplayerDisabledReason() {
      if (this.minecraft.allowsMultiplayer()) {
         return null;
      } else if (this.minecraft.isNameBanned()) {
         return Component.translatable("title.multiplayer.disabled.banned.name");
      } else {
         BanDetails multiplayerBan = this.minecraft.multiplayerBan();
         if (multiplayerBan != null) {
            return multiplayerBan.expires() != null
               ? Component.translatable("title.multiplayer.disabled.banned.temporary")
               : Component.translatable("title.multiplayer.disabled.banned.permanent");
         } else {
            return Component.translatable("title.multiplayer.disabled");
         }
      }
   }

   private int createDemoMenuOptions(int topPos, final int spacing) {
      boolean demoWorldPresent = this.checkDemoWorldPresence();
      this.addRenderableWidget(
         Button.builder(
               Component.translatable("menu.playdemo"),
               button -> {
                  if (demoWorldPresent) {
                     this.minecraft.createWorldOpenFlows().openWorld("Demo_World", () -> this.minecraft.gui.setScreen(this));
                  } else {
                     this.minecraft
                        .createWorldOpenFlows()
                        .createFreshLevel(
                           "Demo_World",
                           MinecraftServer.DEMO_SETTINGS,
                           WorldOptions.DEMO_OPTIONS,
                           WorldPresets::createNormalWorldDimensions,
                           this
                        );
                  }
               }
            )
            .bounds(this.width / 2 - 100, topPos, 200, 20)
            .build()
      );
      int nextY;
      Button resetDemoButton = this.addRenderableWidget(
         Button.builder(
               Component.translatable("menu.resetdemo"),
               button -> {
                  LevelStorageSource levelSource = this.minecraft.getLevelSource();
                  try (LevelStorageSource.LevelStorageAccess levelAccess = levelSource.createAccess("Demo_World")) {
                     if (levelAccess.hasWorldData()) {
                        this.minecraft.gui.setScreen(
                           new ConfirmScreen(
                              this::confirmDemo,
                              Component.translatable("selectWorld.deleteQuestion"),
                              Component.translatable(
                                 "selectWorld.deleteWarning", MinecraftServer.DEMO_SETTINGS.levelName()
                              ),
                              Component.translatable("selectWorld.deleteButton"),
                              CommonComponents.GUI_CANCEL
                           )
                        );
                     }
                  } catch (IOException e) {
                     SystemToast.onWorldAccessFailure(this.minecraft, "Demo_World");
                     LOGGER.warn("Failed to access demo world", e);
                  }
               }
            )
            .bounds(this.width / 2 - 100, nextY = topPos + spacing, 200, 20)
            .build()
      );
      resetDemoButton.active = demoWorldPresent;
      return nextY;
   }

   private boolean checkDemoWorldPresence() {
      try (LevelStorageSource.LevelStorageAccess levelSource = this.minecraft.getLevelSource().createAccess("Demo_World")) {
         return levelSource.hasWorldData();
      } catch (IOException e) {
         SystemToast.onWorldAccessFailure(this.minecraft, "Demo_World");
         LOGGER.warn("Failed to read demo world data", e);
         return false;
      }
   }

   @Override
   public void extractRenderState(final GuiGraphicsExtractor graphics, final int mouseX, final int mouseY, final float a) {
      if (this.fadeInStart == 0L && this.fading) {
         this.fadeInStart = Util.getMillis();
      }

      float widgetFade = 1.0F;
      if (this.fading) {
         float fade = (float)(Util.getMillis() - this.fadeInStart) / 2000.0F;
         if (fade > 1.0F) {
            this.fading = false;
         } else {
            fade = Mth.clamp(fade, 0.0F, 1.0F);
            widgetFade = Mth.clampedMap(fade, 0.5F, 1.0F, 0.0F, 1.0F);
         }
         this.fadeWidgets(widgetFade);
      }

      this.extractPanorama(graphics, a);
      super.extractRenderState(graphics, mouseX, mouseY, a);
      this.logoRenderer.extractRenderState(graphics, this.width, this.logoRenderer.keepLogoThroughFade() ? 1.0F : widgetFade);
      if (this.splash != null && !this.minecraft.options.hideSplashTexts().get()) {
         this.splash.extractRenderState(graphics, this.width, this.font, widgetFade);
      }

      String versionString = "Minecraft " + SharedConstants.getCurrentVersion().name();
      if (this.minecraft.isDemo()) {
         versionString = versionString + " Demo";
      }
      if (Minecraft.checkModStatus().shouldReportAsModified()) {
         versionString = versionString + I18n.get("menu.modded");
      }

      if (net.lax1dude.eaglercraft.v1_8.minecraft.EaglerHosted.isActive()) {
         graphics.text(
            this.font,
            Component.translatableWithFallback(
               "eagler.menu.brand",
               "DeltaClient 8.9",
               net.lax1dude.eaglercraft.v1_8.EaglercraftVersion.projectForkVersion
            ),
            2,
            this.height - 20,
            ARGB.white(widgetFade)
         );
         graphics.text(
            this.font,
            Component.translatableWithFallback(
               "eagler.menu.rewrittenBy",
               "Minecraft 26.2",
               net.lax1dude.eaglercraft.v1_8.EaglercraftVersion.projectForkVendor
            ),
            2,
            this.height - 10,
            ARGB.white(widgetFade)
         );
      } else {
         graphics.text(this.font, versionString, 2, this.height - 10, ARGB.white(widgetFade));
      }
   }

   @Override
   public void extractBackground(final GuiGraphicsExtractor graphics, final int mouseX, final int mouseY, final float a) {
   }

   private void confirmDemo(final boolean result) {
      if (result) {
         try (LevelStorageSource.LevelStorageAccess levelSource = this.minecraft.getLevelSource().createAccess("Demo_World")) {
            levelSource.deleteLevel();
         } catch (IOException e) {
            SystemToast.onWorldDeleteFailure(this.minecraft, "Demo_World");
            LOGGER.warn("Failed to delete demo world", e);
         }
      }
      this.minecraft.gui.setScreen(this);
   }

   @Override
   public boolean canInterruptWithAnotherScreen() {
      return true;
   }
}