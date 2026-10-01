/*
 * Copyright (c) 2022-2024 lax1dude, ayunami2000. All Rights Reserved.
 * 
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
 * WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED.
 * IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 * INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
 * NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR
 * PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 * 
 */

package net.lax1dude.eaglercraft.v1_8.internal;

import net.lax1dude.eaglercraft.v1_8.EagRuntime;
import net.lax1dude.eaglercraft.v1_8.internal.teavm.TeaVMUtils;
import net.lax1dude.eaglercraft.v1_8.log4j.LogManager;
import net.lax1dude.eaglercraft.v1_8.log4j.Logger;
import net.lax1dude.eaglercraft.v1_8.sp.internal.ClientPlatformSingleplayer;
import net.lax1dude.eaglercraft.v1_8.sp.lan.LANPeerEvent;

import org.json.JSONObject;
import org.json.JSONWriter;
import org.teavm.jso.JSBody;
import org.teavm.jso.JSFunctor;
import org.teavm.jso.JSObject;
import org.teavm.jso.browser.TimerHandler;
import org.teavm.jso.browser.Window;
import org.teavm.jso.core.JSError;
import org.teavm.jso.dom.events.Event;
import org.teavm.jso.dom.events.EventListener;
import org.teavm.jso.json.JSON;
import org.teavm.jso.typedarrays.ArrayBuffer;
import org.teavm.jso.websocket.WebSocket;

import java.util.*;

public class PlatformWebRTC {

	private static final Logger logger = LogManager.getLogger("PlatformWebRTC");

	static final int WEBRTC_SUPPORT_NONE = 0;
	static final int WEBRTC_SUPPORT_CORE = 1;
	static final int WEBRTC_SUPPORT_WEBKIT = 2;
	static final int WEBRTC_SUPPORT_MOZ = 3;
	static final int WEBRTC_SUPPORT_CORE_NON_PROMISING = 4;

	@JSBody(script = "var checkPromising = function() { try {"
			+ "return (typeof (new RTCPeerConnection({iceServers:[{urls:\"stun:127.69.0.1:6969\"}]})).createOffer() === \"object\") ? 1 : 4;"
			+ "} catch(ex) {"
			+ "return (ex.name === \"TypeError\") ? 4 : 1;"
			+ "}};"
			+ "return (typeof RTCPeerConnection !== \"undefined\")"
			+ " ? checkPromising()"
			+ " : ((typeof webkitRTCPeerConnection !== \"undefined\") ? 2"
			+ " : ((typeof mozRTCPeerConnection !== \"undefined\") ? 3"
			+ " : 0));")
	private static native int checkSupportedImpl();

	static boolean hasCheckedSupport = false;
	static int supportedImpl = WEBRTC_SUPPORT_NONE;
	static boolean useSessionDescConstructor = false;
	static boolean useOldConnStateCheck = false;
	static boolean belowChrome71Fix = false;

	public static boolean supported() {
		if(!hasCheckedSupport) {
			supportedImpl = checkSupportedImpl();
			hasCheckedSupport = true;
			if(supportedImpl == WEBRTC_SUPPORT_NONE) {
				logger.error("WebRTC is not supported on this browser!");
			}else if(supportedImpl == WEBRTC_SUPPORT_WEBKIT) {
				logger.info("Using webkit- prefix for RTCPeerConnection");
			}else if(supportedImpl == WEBRTC_SUPPORT_MOZ) {
				logger.info("Using moz- prefix for RTCPeerConnection");
			}else if(supportedImpl == WEBRTC_SUPPORT_CORE_NON_PROMISING) {
				logger.info("Using non-promising RTCPeerConnection");
			}
			if(supportedImpl != WEBRTC_SUPPORT_NONE) {
				belowChrome71Fix = isChromeBelow71();
				if(belowChrome71Fix) {
					logger.info("Note: Detected Chrome below version 71, stripping \"a=extmap-allow-mixed\" from the description SDP field");
				}
			}else {
				belowChrome71Fix = false;
			}
		}
		return supportedImpl != WEBRTC_SUPPORT_NONE;
	}

	@JSBody(params = { "item" }, script = "item.close();")
	static native void closeIt(JSObject item);

	@JSBody(params = { "item" }, script = "return item.readyState;")
	static native String getReadyState(JSObject item);

	@JSBody(params = { "item", "buffer" }, script = "item.send(buffer);")
	static native void sendIt(JSObject item, ArrayBuffer buffer);

	@JSBody(params = { "item" }, script = "var n = Number(item && item.bufferedAmount) || 0; return n >= 2147483647 ? 2147483647 : (n | 0);")
	static native int getBufferedAmount(JSObject item);

	@JSBody(params = { "item" }, script = "return !!item.candidate;")
	static native boolean hasCandidate(JSObject item);

	@JSBody(params = { "item" }, script = "return item.connectionState || \"\";")
	private static native String getModernConnectionState(JSObject item);

	@JSBody(params = { "item" }, script = "return item.iceConnectionState;")
	private static native String getICEConnectionState(JSObject item);

	@JSBody(params = { "item" }, script = "return item.signalingState;")
	private static native String getSignalingState(JSObject item);

	static String getConnectionState(JSObject item) {
		if(useOldConnStateCheck) {
			return getConnectionStateLegacy(item);
		}else {
			String str = getModernConnectionState(item);
			if(str.length() == 0) {
				useOldConnStateCheck = true;
				logger.info("Note: Using legacy connection state check using iceConnectionState+signalingState");
				return getConnectionStateLegacy(item);
			}else {
				return str;
			}
		}
	}

	private static String getConnectionStateLegacy(JSObject item) {
		String connState = getICEConnectionState(item);
		switch(connState) {
		case "new":
			return "new";
		case "checking":
			return "connecting";
		case "failed":
			return "failed";
		case "disconnected":
			return "disconnected";
		case "connected":
		case "completed":
		case "closed":
			String signalState = getSignalingState(item);
			switch(signalState) {
			case "stable":
				return "connected";
			case "have-local-offer":
			case "have-remote-offer":
			case "have-local-pranswer":
			case "have-remote-pranswer":
				return "connecting";
			case "closed":
			default:
				return "closed";
			}
		default:
			return "closed";
		}
	}

	@JSBody(params = { "item" }, script = "return item.candidate.sdpMLineIndex;")
	static native int getSdpMLineIndex(JSObject item);

	@JSBody(params = { "item" }, script = "return item.candidate.candidate;")
	static native String getCandidate(JSObject item);

	static JSObject createRTCPeerConnection(String iceServers) {
		if(!hasCheckedSupport) supported();
		switch(supportedImpl) {
		case WEBRTC_SUPPORT_CORE:
		case WEBRTC_SUPPORT_CORE_NON_PROMISING:
			return createCoreRTCPeerConnection(iceServers);
		case WEBRTC_SUPPORT_WEBKIT:
			return createWebkitRTCPeerConnection(iceServers);
		case WEBRTC_SUPPORT_MOZ:
			return createMozRTCPeerConnection(iceServers);
		default:
			throw new UnsupportedOperationException();
		}
	}

	@JSBody(params = { "iceServers" }, script = "return new RTCPeerConnection({ iceServers: JSON.parse(iceServers), optional: [ { DtlsSrtpKeyAgreement: true } ] });")
	static native JSObject createCoreRTCPeerConnection(String iceServers);

	@JSBody(params = { "iceServers" }, script = "return new webkitRTCPeerConnection({ iceServers: JSON.parse(iceServers), optional: [ { DtlsSrtpKeyAgreement: true } ] });")
	static native JSObject createWebkitRTCPeerConnection(String iceServers);

	@JSBody(params = { "iceServers" }, script = "return new mozRTCPeerConnection({ iceServers: JSON.parse(iceServers), optional: [ { DtlsSrtpKeyAgreement: true } ] });")
	static native JSObject createMozRTCPeerConnection(String iceServers);

	@JSBody(params = { "peerConnection", "name" }, script = "return peerConnection.createDataChannel(name);")
	static native JSObject createDataChannel(JSObject peerConnection, String name);

	@JSBody(params = { "item", "type" }, script = "item.binaryType = type;")
	static native void setBinaryType(JSObject item, String type);

	@JSBody(params = { "item" }, script = "return item.data;")
	static native ArrayBuffer getData(JSObject item);

	@JSBody(params = { "item" }, script = "return item.channel;")
	static native JSObject getChannel(JSObject item);

	@JSBody(params = { "peerConnection", "h1", "h2" }, script = "peerConnection.createOffer().then(h1).catch(h2);")
	private static native void createOfferPromising(JSObject peerConnection, DescHandler h1, ErrorHandler h2);

	@JSBody(params = { "peerConnection", "h1", "h2" }, script = "peerConnection.createOffer(h1, h2);")
	private static native void createOfferLegacy(JSObject peerConnection, DescHandler h1, ErrorHandler h2);

	static void createOffer(JSObject peerConnection, DescHandler h1, ErrorHandler h2) {
		if(!hasCheckedSupport) supported();
		switch(supportedImpl) {
		case WEBRTC_SUPPORT_CORE:
			createOfferPromising(peerConnection, h1, h2);
			break;
		case WEBRTC_SUPPORT_WEBKIT:
		case WEBRTC_SUPPORT_MOZ:
		case WEBRTC_SUPPORT_CORE_NON_PROMISING:
			createOfferLegacy(peerConnection, h1, h2);
			break;
		default:
			throw new UnsupportedOperationException();
		}
	}

	@JSBody(params = { "peerConnection", "desc", "h1", "h2" }, script = "peerConnection.setLocalDescription(desc).then(h1).catch(h2);")
	private static native void setLocalDescriptionPromising(JSObject peerConnection, JSObject desc, EmptyHandler h1, ErrorHandler h2);

	@JSBody(params = { "peerConnection", "desc", "h1", "h2" }, script = "peerConnection.setLocalDescription(desc, h1, h2);")
	private static native void setLocalDescriptionLegacy(JSObject peerConnection, JSObject desc, EmptyHandler h1, ErrorHandler h2);

	static void setLocalDescription(JSObject peerConnection, JSObject desc, EmptyHandler h1, ErrorHandler h2) {
		if(!hasCheckedSupport) supported();
		switch(supportedImpl) {
		case WEBRTC_SUPPORT_CORE:
			setLocalDescriptionPromising(peerConnection, desc, h1, h2);
			break;
		case WEBRTC_SUPPORT_WEBKIT:
		case WEBRTC_SUPPORT_MOZ:
		case WEBRTC_SUPPORT_CORE_NON_PROMISING:
			setLocalDescriptionLegacy(peerConnection, desc, h1, h2);
			break;
		default:
			throw new UnsupportedOperationException();
		}
	}

	@JSBody(params = { "peerConnection", "str" }, script = "var candidateList = JSON.parse(str); for (var i = 0; i < candidateList.length; ++i) { peerConnection.addIceCandidate(new RTCIceCandidate(candidateList[i])); }; return null;")
	private static native void addCoreIceCandidates(JSObject peerConnection, String str);

	@JSBody(params = { "peerConnection", "str" }, script = "var candidateList = JSON.parse(str); for (var i = 0; i < candidateList.length; ++i) { peerConnection.addIceCandidate(new mozRTCIceCandidate(candidateList[i])); }; return null;")
	private static native void addMozIceCandidates(JSObject peerConnection, String str);

	@JSBody(params = { }, script = "if(!navigator || !navigator.userAgent) return false;"
			+ "var ua = navigator.userAgent.toLowerCase();"
			+ "var i = ua.indexOf(\"chrome/\");"
			+ "if(i === -1) return false;"
			+ "i += 7;"
			+ "var j = ua.indexOf(\".\", i);"
			+ "if(j === -1 || j < i) j = ua.length;"
			+ "var versStr = ua.substring(i, j);"
			+ "versStr = parseInt(versStr);"
			+ "return !isNaN(versStr) && versStr < 71;")
	private static native boolean isChromeBelow71();

	static void addIceCandidates(JSObject peerConnection, String str) {
		if(!hasCheckedSupport) supported();
		switch(supportedImpl) {
		case WEBRTC_SUPPORT_CORE:
		case WEBRTC_SUPPORT_CORE_NON_PROMISING:
		case WEBRTC_SUPPORT_WEBKIT:
			addCoreIceCandidates(peerConnection, str);
			break;
		case WEBRTC_SUPPORT_MOZ:
			addMozIceCandidates(peerConnection, str);
			break;
		default:
			throw new UnsupportedOperationException();
		}
	}

	@JSBody(params = { "peerConnection", "str" }, script = "try { peerConnection.setRemoteDescription(str); return true; } catch(ex) { if(ex.name === \"TypeError\") return false; else throw ex; }")
	private static native boolean setCoreRemoteDescription(JSObject peerConnection, JSObject str);

	@JSBody(params = { "peerConnection", "str" }, script = "peerConnection.setRemoteDescription(new RTCSessionDescription(str));")
	private static native void setCoreRemoteDescriptionLegacy(JSObject peerConnection, JSObject str);

	@JSBody(params = { "peerConnection", "str" }, script = "peerConnection.setRemoteDescription(new mozRTCSessionDescription(str));")
	private static native void setMozRemoteDescriptionLegacy(JSObject peerConnection, JSObject str);

	static void setRemoteDescription(JSObject peerConnection, JSObject str) {
		if(!hasCheckedSupport) supported();
		if(belowChrome71Fix) {
			removeExtmapAllowMixed(str);
		}
		switch(supportedImpl) {
		case WEBRTC_SUPPORT_CORE:
		case WEBRTC_SUPPORT_CORE_NON_PROMISING:
			if(useSessionDescConstructor) {
				setCoreRemoteDescriptionLegacy(peerConnection, str);
			}else {
				if(!setCoreRemoteDescription(peerConnection, str)) {
					useSessionDescConstructor = true;
					logger.info("Note: Caught suspicious exception, using legacy RTCSessionDescription method");
					setCoreRemoteDescriptionLegacy(peerConnection, str);
				}
			}
			break;
		case WEBRTC_SUPPORT_WEBKIT:
			setCoreRemoteDescriptionLegacy(peerConnection, str);
			break;
		case WEBRTC_SUPPORT_MOZ:
			setMozRemoteDescriptionLegacy(peerConnection, str);
			break;
		default:
			throw new UnsupportedOperationException();
		}
	}

	@JSBody(params = { "peerConnection", "str", "h1", "h2" }, script = "try { peerConnection.setRemoteDescription(str).then(h1).catch(h2); return true; } catch(ex) { if(ex.name === \"TypeError\") return false; else throw ex; }")
	private static native boolean setCoreRemoteDescription2Promising(JSObject peerConnection, JSObject str, EmptyHandler h1, ErrorHandler h2);

	@JSBody(params = { "peerConnection", "str", "h1", "h2" }, script = "try { peerConnection.setRemoteDescription(str, h1, h2); return true; } catch(ex) { if(ex.name === \"TypeError\") return false; else throw ex; }")
	private static native boolean setCoreRemoteDescription2Legacy(JSObject peerConnection, JSObject str, EmptyHandler h1, ErrorHandler h2);

	@JSBody(params = { "peerConnection", "str", "h1", "h2" }, script = "peerConnection.setRemoteDescription(new RTCSessionDescription(str)).then(h1).catch(h2);")
	private static native void setCoreRemoteDescription2PromisingLegacy(JSObject peerConnection, JSObject str, EmptyHandler h1, ErrorHandler h2);

	@JSBody(params = { "peerConnection", "str", "h1", "h2" }, script = "peerConnection.setRemoteDescription(new RTCSessionDescription(str), h1, h2);")
	private static native void setCoreRemoteDescription2LegacyLegacy(JSObject peerConnection, JSObject str, EmptyHandler h1, ErrorHandler h2);

	@JSBody(params = { "peerConnection", "str", "h1", "h2" }, script = "peerConnection.setRemoteDescription(new mozRTCSessionDescription(str), h1, h2);")
	private static native void setMozRemoteDescription2LegacyLegacy(JSObject peerConnection, JSObject str, EmptyHandler h1, ErrorHandler h2);

	static void setRemoteDescription2(JSObject peerConnection, JSObject str, EmptyHandler h1, ErrorHandler h2) {
		if(!hasCheckedSupport) supported();
		if(belowChrome71Fix) {
			removeExtmapAllowMixed(str);
		}
		switch(supportedImpl) {
		case WEBRTC_SUPPORT_CORE:
			if(useSessionDescConstructor) {
				setCoreRemoteDescription2PromisingLegacy(peerConnection, str, h1, h2);
			}else {
				if(!setCoreRemoteDescription2Promising(peerConnection, str, h1, h2)) {
					useSessionDescConstructor = true;
					logger.info("Note: Caught suspicious exception, using legacy RTCSessionDescription method");
					setCoreRemoteDescription2PromisingLegacy(peerConnection, str, h1, h2);
				}
			}
			break;
		case WEBRTC_SUPPORT_WEBKIT:
			setCoreRemoteDescription2LegacyLegacy(peerConnection, str, h1, h2);
			break;
		case WEBRTC_SUPPORT_MOZ:
			setMozRemoteDescription2LegacyLegacy(peerConnection, str, h1, h2);
			break;
		case WEBRTC_SUPPORT_CORE_NON_PROMISING:
			if(useSessionDescConstructor) {
				setCoreRemoteDescription2LegacyLegacy(peerConnection, str, h1, h2);
			}else {
				if(!setCoreRemoteDescription2Legacy(peerConnection, str, h1, h2)) {
					useSessionDescConstructor = true;
					logger.info("Note: Caught suspicious exception, using legacy RTCSessionDescription method");
					setCoreRemoteDescription2LegacyLegacy(peerConnection, str, h1, h2);
				}
			}
			break;
		default:
			throw new UnsupportedOperationException();
		}
	}

	@JSBody(params = { "objIn" }, script = "if(typeof objIn.sdp === \"string\""
			+ "&& objIn.sdp.indexOf(\"a=extmap-allow-mixed\") !== -1) {"
			+ "objIn.sdp = objIn.sdp.split(\"\\n\").filter(function(line) {"
			+ "return line.trim() !== \"a=extmap-allow-mixed\";"
			+ "}).join(\"\\n\");"
			+ "}")
	private static native void removeExtmapAllowMixed(JSObject objIn);

	@JSBody(params = { "peerConnection", "h1", "h2" }, script = "peerConnection.createAnswer().then(h1).catch(h2);")
	private static native void createAnswerPromising(JSObject peerConnection, DescHandler h1, ErrorHandler h2);

	@JSBody(params = { "peerConnection", "h1", "h2" }, script = "peerConnection.createAnswer(h1, h2);")
	private static native void createAnswerLegacy(JSObject peerConnection, DescHandler h1, ErrorHandler h2);

	static void createAnswer(JSObject peerConnection, DescHandler h1, ErrorHandler h2) {
		if(!hasCheckedSupport) supported();
		switch(supportedImpl) {
		case WEBRTC_SUPPORT_CORE:
			createAnswerPromising(peerConnection, h1, h2);
			break;
		case WEBRTC_SUPPORT_WEBKIT:
		case WEBRTC_SUPPORT_MOZ:
		case WEBRTC_SUPPORT_CORE_NON_PROMISING:
			createAnswerLegacy(peerConnection, h1, h2);
			break;
		default:
			throw new UnsupportedOperationException();
		}
	}

	@JSBody(params = { "sock", "buffer" }, script = "sock.send(buffer);")
	static native void nativeBinarySend(WebSocket sock, ArrayBuffer buffer);

	public static void runScheduledTasks() {
		
	}

	public static class LANClient {
		public static final byte READYSTATE_INIT_FAILED = -2;
		public static final byte READYSTATE_FAILED = -1;
		public static final byte READYSTATE_DISCONNECTED = 0;
		public static final byte READYSTATE_CONNECTING = 1;
		public static final byte READYSTATE_CONNECTED = 2;

		public Set<Map<String, String>> iceServers = new HashSet<>();
		public JSObject peerConnection = null;
		public JSObject dataChannel = null;

		public byte readyState = READYSTATE_CONNECTING;
		private int transportGeneration = 0;
		private final List<RTCListenerBinding> listeners = new ArrayList<>();
		private int iceCandidateTimer = -1;
		private int channelOpenTimer = -1;
		private TimerHandler iceCandidateTimerHandler = null;
		private TimerHandler channelOpenTimerHandler = null;

		public void initialize() {
			teardownTransport();
			try {
				this.peerConnection = createRTCPeerConnection(JSONWriter.valueToString(iceServers));
				this.readyState = READYSTATE_CONNECTING;
			} catch (Throwable t) {
				readyState = READYSTATE_INIT_FAILED;
			}
		}

		public void setIceServers(String[] urls) {
			iceServers.clear();
			for (String url : urls) {
				String[] etr = url.split(";");
				if (etr.length == 1) {
					Map<String, String> m = new HashMap<>();
					m.put("urls", etr[0]);
					iceServers.add(m);
				} else if (etr.length == 3) {
					Map<String, String> m = new HashMap<>();
					m.put("urls", etr[0]);
					m.put("username", etr[1]);
					m.put("credential", etr[2]);
					iceServers.add(m);
				}
			}
		}

		public void sendPacketToServer(ArrayBuffer buffer) {
			if (dataChannel != null && "open".equals(getReadyState(dataChannel))) {
				try {
					sendIt(dataChannel, buffer);
				} catch (Throwable e) {
					signalRemoteDisconnect(false);
				}
			}else {
				signalRemoteDisconnect(false);
			}
		}

		public void signalRemoteConnect() {
			final int generation = transportGeneration;
			final JSObject connection = peerConnection;
			final List<Map<String, String>> iceCandidates = new ArrayList<>();
			final int[] candidateState = new int[2];
			final TimerHandler[] candidateTimer = new TimerHandler[1];
			candidateTimer[0] = () -> {
				if(!isActive(generation, connection)) {
					clearIceCandidateTimer(candidateTimer[0]);
					return;
				}
				int trial = ++candidateState[1];
				if(candidateState[0] != iceCandidates.size() && trial < 3) {
					candidateState[0] = iceCandidates.size();
					iceCandidateTimer = Window.setTimeout(candidateTimer[0], 2000);
					return;
				}
				clientICECandidate = JSONWriter.valueToString(iceCandidates);
				iceCandidates.clear();
				clearIceCandidateTimer(candidateTimer[0]);
			};

			listen(connection, "icecandidate", evt -> {
				if(!isActive(generation, connection)) return;
				if (hasCandidate(evt)) {
					if (iceCandidates.isEmpty()) {
						iceCandidateTimerHandler = candidateTimer[0];
						iceCandidateTimer = Window.setTimeout(candidateTimer[0], 2000);
					}
					Map<String, String> m = new HashMap<>();
					m.put("sdpMLineIndex", "" + getSdpMLineIndex(evt));
					m.put("candidate", getCandidate(evt));
					iceCandidates.add(m);
				}
			});

			final JSObject channel = dataChannel = createDataChannel(connection, "lan");
			setBinaryType(channel, "arraybuffer");

			final TimerHandler[] openTimer = new TimerHandler[1];
			openTimer[0] = () -> {
				if(!isActive(generation, connection) || dataChannel != channel) {
					clearChannelOpenTimer(openTimer[0]);
					return;
				}
				if(!iceCandidates.isEmpty()) {
					channelOpenTimer = Window.setTimeout(openTimer[0], 10);
					return;
				}
				clientDataChannelClosed = false;
				clientDataChannelOpen = true;
				clearChannelOpenTimer(openTimer[0]);
			};

			listen(channel, "open", evt -> {
				if(!isActive(generation, connection) || dataChannel != channel) return;
				if(channelOpenTimer == -1) {
					channelOpenTimerHandler = openTimer[0];
					channelOpenTimer = Window.setTimeout(openTimer[0], 0);
				}
			});

			listen(channel, "message", evt -> {
				if(!isActive(generation, connection) || dataChannel != channel) return;
				synchronized(clientLANPacketBuffer) {
					byte[] packet = TeaVMUtils.wrapByteArrayBuffer(getData(evt));
					clientLANPacketBuffer.add(packet);
					clientLANPacketBufferBytes += packet.length;
				}
			});
			listen(channel, "close", evt -> {
				if(isActive(generation, connection) && dataChannel == channel) signalRemoteDisconnect(false);
			});
			listen(channel, "error", evt -> {
				if(isActive(generation, connection) && dataChannel == channel) signalRemoteDisconnect(false);
			});

			createOffer(connection, desc -> {
				if(!isActive(generation, connection)) return;
				setLocalDescription(connection, desc, () -> {
					if(!isActive(generation, connection)) return;
					clientDescription = JSON.stringify(desc);
				}, err -> {
					if(!isActive(generation, connection)) return;
					logger.error("Failed to set local description! {}", err.getMessage());
					readyState = READYSTATE_FAILED;
					signalRemoteDisconnect(false);
				});
			}, err -> {
				if(!isActive(generation, connection)) return;
				logger.error("Failed to set create offer! {}", err.getMessage());
				readyState = READYSTATE_FAILED;
				signalRemoteDisconnect(false);
			});

			listen(connection, "connectionstatechange", evt -> {
				if(!isActive(generation, connection)) return;
				String connectionState = getConnectionState(connection);
				if ("disconnected".equals(connectionState)) {
					signalRemoteDisconnect(false);
				} else if ("connected".equals(connectionState)) {
					readyState = READYSTATE_CONNECTED;
				} else if ("failed".equals(connectionState)) {
					readyState = READYSTATE_FAILED;
					signalRemoteDisconnect(false);
				}
			});
		}

		public void signalRemoteDescription(String json) {
			try {
				if(peerConnection == null) throw new IllegalStateException("WebRTC peer is closed");
				setRemoteDescription(peerConnection, JSON.parse(json));
			} catch (Throwable t) {
				EagRuntime.debugPrintStackTrace(t);
				readyState = READYSTATE_FAILED;
				signalRemoteDisconnect(false);
			}
		}

		public void signalRemoteICECandidate(String candidates) {
			try {
				if(peerConnection == null) throw new IllegalStateException("WebRTC peer is closed");
				addIceCandidates(peerConnection, candidates);
			} catch (Throwable t) {
				EagRuntime.debugPrintStackTrace(t);
				readyState = READYSTATE_FAILED;
				signalRemoteDisconnect(false);
			}
		}

		public void signalRemoteDisconnect(boolean quiet) {
			teardownTransport();
			if (!quiet) clientDataChannelClosed = true;
			readyState = READYSTATE_DISCONNECTED;
		}

		private boolean isActive(int generation, JSObject connection) {
			return transportGeneration == generation && peerConnection == connection;
		}

		private void listen(JSObject target, String name, RTCEventHandler handler) {
			listeners.add(new RTCListenerBinding(target, name, handler));
			addRTCEventListener(target, name, handler);
		}

		private void clearIceCandidateTimer(TimerHandler handler) {
			if(iceCandidateTimerHandler == handler) {
				iceCandidateTimer = -1;
				iceCandidateTimerHandler = null;
			}
		}

		private void clearChannelOpenTimer(TimerHandler handler) {
			if(channelOpenTimerHandler == handler) {
				channelOpenTimer = -1;
				channelOpenTimerHandler = null;
			}
		}

		private void teardownTransport() {
			++transportGeneration;
			if(iceCandidateTimer != -1) Window.clearTimeout(iceCandidateTimer);
			if(channelOpenTimer != -1) Window.clearTimeout(channelOpenTimer);
			iceCandidateTimer = channelOpenTimer = -1;
			iceCandidateTimerHandler = channelOpenTimerHandler = null;
			clearRTCEventListeners(listeners);
			JSObject channel = dataChannel;
			JSObject connection = peerConnection;
			dataChannel = null;
			peerConnection = null;
			if(channel != null) {
				try { closeIt(channel); } catch(Throwable ignored) {}
			}
			if(connection != null) {
				try { closeIt(connection); } catch(Throwable ignored) {}
			}
		}
	}

	public static class LANPeer {
		public LANServer client;
		public String peerId;
		public JSObject peerConnection;
		public JSObject dataChannel;
		public String ipcChannel;
		private boolean disconnected;
		private final List<RTCListenerBinding> listeners = new ArrayList<>();
		private int iceCandidateTimer = -1;
		private TimerHandler iceCandidateTimerHandler = null;

		public LANPeer(LANServer client, String peerId, JSObject peerConnection) {
			this.client = client;
			this.peerId = peerId;
			this.peerConnection = peerConnection;

			final JSObject connection = peerConnection;
			final List<Map<String, String>> iceCandidates = new ArrayList<>();
			final int[] candidateState = new int[2];
			final TimerHandler[] candidateTimer = new TimerHandler[1];
			candidateTimer[0] = () -> {
				if(!isActive(connection)) {
					clearIceCandidateTimer(candidateTimer[0]);
					return;
				}
				int trial = ++candidateState[1];
				if(candidateState[0] != iceCandidates.size() && trial < 3) {
					candidateState[0] = iceCandidates.size();
					iceCandidateTimer = Window.setTimeout(candidateTimer[0], 2000);
					return;
				}
				LANPeerEvent.LANPeerICECandidateEvent e = new LANPeerEvent.LANPeerICECandidateEvent(peerId,
						JSONWriter.valueToString(iceCandidates));
				addServerLANEvent(peerId, e);
				iceCandidates.clear();
				clearIceCandidateTimer(candidateTimer[0]);
			};

			listen(connection, "icecandidate", evt -> {
				if(!isActive(connection)) return;
				if (hasCandidate(evt)) {
					if (iceCandidates.isEmpty()) {
						iceCandidateTimerHandler = candidateTimer[0];
						iceCandidateTimer = Window.setTimeout(candidateTimer[0], 2000);
					}
					Map<String, String> m = new HashMap<>();
					m.put("sdpMLineIndex", "" + getSdpMLineIndex(evt));
					m.put("candidate", getCandidate(evt));
					iceCandidates.add(m);
				}
			});

			listen(connection, "datachannel", evt -> {
				if(!isActive(connection)) return;
				if (getChannel(evt) == null) return;
				final JSObject dataChannel = getChannel(evt);
				if(this.dataChannel != null) {
					closeIt(dataChannel);
					return;
				}
				this.dataChannel = dataChannel;
				setBinaryType(dataChannel, "arraybuffer");
				listen(dataChannel, "open", evt2 -> {
					if(isActive(connection) && this.dataChannel == dataChannel) {
						addServerLANEvent(peerId, new LANPeerEvent.LANPeerDataChannelEvent(peerId));
					}
				});
				listen(dataChannel, "message", evt2 -> {
					if(!isActive(connection) || this.dataChannel != dataChannel) return;
					ArrayBuffer data = getData(evt2);
					if(ipcChannel != null) {
						ClientPlatformSingleplayer.sendPacketTeaVM(ipcChannel, data);
					}else {
						LANPeerEvent.LANPeerPacketEvent e = new LANPeerEvent.LANPeerPacketEvent(peerId, TeaVMUtils.wrapByteArrayBuffer(data));
						addServerLANEvent(peerId, e);
					}
				});
				listen(dataChannel, "close", evt2 -> {
					if(isActive(connection) && this.dataChannel == dataChannel) client.signalRemoteDisconnect(peerId);
				});
				listen(dataChannel, "error", evt2 -> {
					if(isActive(connection) && this.dataChannel == dataChannel) client.signalRemoteDisconnect(peerId);
				});
				if("open".equals(getReadyState(dataChannel))) {
					addServerLANEvent(peerId, new LANPeerEvent.LANPeerDataChannelEvent(peerId));
				}
			});

			listen(connection, "connectionstatechange", evt -> {
				if(!isActive(connection)) return;
				String connectionState = getConnectionState(connection);
				if ("disconnected".equals(connectionState) || "failed".equals(connectionState)) {
					client.signalRemoteDisconnect(peerId);
				}
			});
		}

		public void disconnect() {
			if(disconnected) return;
			disconnected = true;
			if(iceCandidateTimer != -1) Window.clearTimeout(iceCandidateTimer);
			iceCandidateTimer = -1;
			iceCandidateTimerHandler = null;
			clearRTCEventListeners(listeners);
			JSObject channel = dataChannel;
			JSObject connection = peerConnection;
			dataChannel = null;
			peerConnection = null;
			if(channel != null) {
				try { closeIt(channel); } catch(Throwable ignored) {}
			}
			if(connection != null) {
				try { closeIt(connection); } catch(Throwable ignored) {}
			}
		}

		public void setRemoteDescription(String descJSON) {
			try {
				final JSObject connection = peerConnection;
				if(!isActive(connection)) throw new IllegalStateException("WebRTC peer is closed");
				JSONObject remoteDesc = new JSONObject(descJSON);
				setRemoteDescription2(connection, JSON.parse(descJSON), () -> {
					if(!isActive(connection)) return;
					if (remoteDesc.has("type") && "offer".equals(remoteDesc.getString("type"))) {
						createAnswer(connection, desc -> {
							if(!isActive(connection)) return;
							setLocalDescription(connection, desc, () -> {
								if(!isActive(connection)) return;
								LANPeerEvent.LANPeerDescriptionEvent e = new LANPeerEvent.LANPeerDescriptionEvent(peerId, JSON.stringify(desc));
								addServerLANEvent(peerId, e);
							}, err -> {
								if(!isActive(connection)) return;
								logger.error("Failed to set local description for \"{}\"! {}", peerId, TeaVMUtils.safeErrorMsgToString(err));
								client.signalRemoteDisconnect(peerId);
							});
						}, err -> {
							if(!isActive(connection)) return;
							logger.error("Failed to create answer for \"{}\"! {}", peerId, TeaVMUtils.safeErrorMsgToString(err));
							client.signalRemoteDisconnect(peerId);
						});
					}
				}, err -> {
					if(!isActive(connection)) return;
					logger.error("Failed to set remote description for \"{}\"! {}", peerId, TeaVMUtils.safeErrorMsgToString(err));
					client.signalRemoteDisconnect(peerId);
				});
			} catch (Throwable err) {
				logger.error("Failed to parse remote description for \"{}\"! {}", peerId, err.getMessage());
				logger.error(err);
				client.signalRemoteDisconnect(peerId);
			}
		}

		public void addICECandidate(String candidates) {
			try {
				if(!isActive(peerConnection)) throw new IllegalStateException("WebRTC peer is closed");
				addIceCandidates(peerConnection, candidates);
			} catch (Throwable err) {
				logger.error("Failed to parse ice candidate for \"{}\"! {}", peerId, err.getMessage());
				client.signalRemoteDisconnect(peerId);
			}
		}

		public void mapIPC(String ipcChannel) {
			if(this.ipcChannel == null) {
				if(ipcChannel != null) {
					this.ipcChannel = ipcChannel;
					this.client.ipcMapList.put(ipcChannel, this);
				}
			}else {
				if(ipcChannel == null) {
					this.client.ipcMapList.remove(this.ipcChannel);
					this.ipcChannel = null;
				}
			}
		}

		private boolean isActive(JSObject connection) {
			return !disconnected && connection != null && peerConnection == connection;
		}

		private void listen(JSObject target, String name, RTCEventHandler handler) {
			listeners.add(new RTCListenerBinding(target, name, handler));
			addRTCEventListener(target, name, handler);
		}

		private void clearIceCandidateTimer(TimerHandler handler) {
			if(iceCandidateTimerHandler == handler) {
				iceCandidateTimer = -1;
				iceCandidateTimerHandler = null;
			}
		}
	}

	public static class LANServer {
		public Set<Map<String, String>> iceServers = new HashSet<>();
		public Map<String, LANPeer> peerList = new HashMap<>();
		public Map<String, LANPeer> ipcMapList = new HashMap<>();

		public void setIceServers(String[] urls) {
			iceServers.clear();
			for (String url : urls) {
				String[] etr = url.split(";");
				if (etr.length == 1) {
					Map<String, String> m = new HashMap<>();
					m.put("urls", etr[0]);
					iceServers.add(m);
				} else if (etr.length == 3) {
					Map<String, String> m = new HashMap<>();
					m.put("urls", etr[0]);
					m.put("username", etr[1]);
					m.put("credential", etr[2]);
					iceServers.add(m);
				}
			}
		}

		public void sendPacketToRemoteClient(String peerId, ArrayBuffer buffer) {
			LANPeer thePeer = this.peerList.get(peerId);
			if (thePeer != null) {
				sendPacketToRemoteClient(thePeer, buffer);
			}
		}

		public void sendPacketToRemoteClient(LANPeer thePeer, ArrayBuffer buffer) {
			boolean b = false;
			if (thePeer.dataChannel != null && "open".equals(getReadyState(thePeer.dataChannel))) {
				try {
					sendIt(thePeer.dataChannel, buffer);
				} catch (Throwable e) {
					b = true;
				}
			} else {
				b = true;
			}
			if(b) {
				signalRemoteDisconnect(thePeer.peerId);
			}
		}

		public void signalRemoteConnect(String peerId) {
			try {
				LANPeer previous = peerList.remove(peerId);
				if(previous != null) previous.disconnect();
				JSObject peerConnection = createRTCPeerConnection(JSONWriter.valueToString(iceServers));
				LANPeer peerInstance = new LANPeer(this, peerId, peerConnection);
				peerList.put(peerId, peerInstance);
			} catch (Throwable e) {
				logger.error("Failed to create peer for \"{}\"", peerId);
				logger.error(e);
				signalRemoteDisconnect(peerId);
			}
		}

		public void signalRemoteDescription(String peerId, String descJSON) {
			LANPeer thePeer = peerList.get(peerId);
			if (thePeer != null) {
				thePeer.setRemoteDescription(descJSON);
			}
		}

		public void signalRemoteICECandidate(String peerId, String candidate) {
			LANPeer thePeer = peerList.get(peerId);
			if (thePeer != null) {
				thePeer.addICECandidate(candidate);
			}
		}

		public void signalRemoteDisconnect(String peerId) {
			if (peerId == null || peerId.isEmpty()) {
				for (LANPeer thePeer : peerList.values()) {
					if (thePeer != null) {
						try {
							thePeer.disconnect();
						} catch (Throwable ignored) {}
						addServerLANEvent(thePeer.peerId, new LANPeerEvent.LANPeerDisconnectEvent(thePeer.peerId));
					}
				}
				peerList.clear();
				ipcMapList.clear();
				return;
			}
			LANPeer thePeer = peerList.remove(peerId);
			if(thePeer != null) {
				if(thePeer.ipcChannel != null) {
					ipcMapList.remove(thePeer.ipcChannel);
				}
				try {
					thePeer.disconnect();
				} catch (Throwable ignored) {}
				addServerLANEvent(thePeer.peerId, new LANPeerEvent.LANPeerDisconnectEvent(peerId));
			}
		}

		public void serverPeerMapIPC(String peer, String ipcChannel) {
			LANPeer peerr = peerList.get(peer);
			if(peerr != null) {
				peerr.mapIPC(ipcChannel);
			}
		}

		public int countPeers() {
			return peerList.size();
		}
	}

	@JSFunctor
	public interface EmptyHandler extends JSObject {
		void call();
	}

	@JSFunctor
	public interface DescHandler extends JSObject {
		void call(JSObject desc);
	}

	@JSFunctor
	public interface ErrorHandler extends JSObject {
		void call(JSError err);
	}

	/**
	 * TeaVM 0.13 must see the listener as a JS functor at the native boundary.
	 * Passing a DOM {@link EventListener} through a plain {@link JSObject}
	 * parameter boxes the lambda as a Java listener object; WebRTC later invokes
	 * that wrapper and the generated {@code handleEvent} bridge tries to call a
	 * non-function.  Keep this callback type explicit for the dynamically typed
	 * RTCPeerConnection/RTCDataChannel objects used by the legacy LAN protocol.
	 */
	@JSFunctor
	private interface RTCEventHandler extends JSObject {
		void call(Event evt);
	}

	@JSBody(params = { "target", "name", "handler" }, script = "target.addEventListener(name, handler);")
	private static native void addRTCEventListener(JSObject target, String name, RTCEventHandler handler);

	@JSBody(params = { "target", "name", "handler" }, script = "target.removeEventListener(name, handler);")
	private static native void removeRTCEventListener(JSObject target, String name, RTCEventHandler handler);

	private static final class RTCListenerBinding {
		final JSObject target;
		final String name;
		final RTCEventHandler handler;

		RTCListenerBinding(JSObject target, String name, RTCEventHandler handler) {
			this.target = target;
			this.name = name;
			this.handler = handler;
		}
	}

	private static void clearRTCEventListeners(List<RTCListenerBinding> listeners) {
		for(int i = listeners.size() - 1; i >= 0; --i) {
			RTCListenerBinding binding = listeners.get(i);
			try {
				removeRTCEventListener(binding.target, binding.name, binding.handler);
			}catch(Throwable ignored) {
			}
		}
		listeners.clear();
	}

	private static LANClient rtcLANClient = null;

	public static void startRTCLANClient() {
		if (rtcLANClient == null) {
			rtcLANClient = new LANClient();
		}
	}

	private static final List<byte[]> clientLANPacketBuffer = new LinkedList<>();
	private static long clientLANPacketBufferBytes = 0L;

	private static String clientICECandidate = null;
	private static String clientDescription = null;
	private static boolean clientDataChannelOpen = false;
	private static boolean clientDataChannelClosed = true;

	public static int clientLANReadyState() {
		return rtcLANClient.readyState;
	}

	public static void clientLANCloseConnection() {
		rtcLANClient.signalRemoteDisconnect(false);
	}

	public static void clientLANSendPacket(byte[] pkt) {
		rtcLANClient.sendPacketToServer(TeaVMUtils.unwrapArrayBuffer(pkt));
	}

	public static byte[] clientLANReadPacket() {
		synchronized(clientLANPacketBuffer) {
			if(clientLANPacketBuffer.isEmpty()) {
				return null;
			}
			byte[] packet = clientLANPacketBuffer.remove(0);
			clientLANPacketBufferBytes -= packet.length;
			return packet;
		}
	}

	public static List<byte[]> clientLANReadAllPacket() {
		synchronized(clientLANPacketBuffer) {
			if(!clientLANPacketBuffer.isEmpty()) {
				List<byte[]> ret = new ArrayList<>(clientLANPacketBuffer);
				clientLANPacketBuffer.clear();
				clientLANPacketBufferBytes = 0L;
				return ret;
			}else {
				return null;
			}
		}
	}

	/**
	 * Drain a bounded part of the WebRTC queue. Initial chunk delivery can enqueue
	 * hundreds of data-channel messages at once; copying the entire queue into the
	 * render thread makes the browser unresponsive before it can present terrain.
	 */
	public static List<byte[]> clientLANReadPacketBatch(int maxPackets, int maxBytes) {
		synchronized(clientLANPacketBuffer) {
			if(clientLANPacketBuffer.isEmpty()) {
				return null;
			}
			List<byte[]> ret = new ArrayList<>(Math.min(maxPackets, clientLANPacketBuffer.size()));
			int bytes = 0;
			while(ret.size() < maxPackets && !clientLANPacketBuffer.isEmpty()) {
				byte[] next = clientLANPacketBuffer.get(0);
				if(!ret.isEmpty() && bytes + next.length > maxBytes) {
					break;
				}
				clientLANPacketBuffer.remove(0);
				ret.add(next);
				bytes += next.length;
				clientLANPacketBufferBytes -= next.length;
			}
			return ret;
		}
	}

	public static int clientLANPendingPacketCount() {
		synchronized(clientLANPacketBuffer) {
			return clientLANPacketBuffer.size();
		}
	}

	public static long clientLANPendingPacketBytes() {
		synchronized(clientLANPacketBuffer) {
			return clientLANPacketBufferBytes;
		}
	}

	public static void clearLANClientPackets() {
		synchronized(clientLANPacketBuffer) {
			clientLANPacketBuffer.clear();
			clientLANPacketBufferBytes = 0L;
		}
	}

	public static void clientLANSetICEServersAndConnect(String[] servers) {
		rtcLANClient.setIceServers(servers);
		if(clientLANReadyState() == LANClient.READYSTATE_CONNECTED || clientLANReadyState() == LANClient.READYSTATE_CONNECTING) {
			rtcLANClient.signalRemoteDisconnect(true);
		}
		rtcLANClient.initialize();
		rtcLANClient.signalRemoteConnect();
	}

	public static void clearLANClientState() {
		clientICECandidate = null;
		clientDescription = null;
		clientDataChannelOpen = false;
		clientDataChannelClosed = true;
		synchronized(clientLANPacketBuffer) {
			clientLANPacketBuffer.clear();
			clientLANPacketBufferBytes = 0L;
		}
	}

	public static String clientLANAwaitICECandidate() {
		if(clientICECandidate != null) {
			String ret = clientICECandidate;
			clientICECandidate = null;
			return ret;
		}else {
			return null;
		}
	}

	public static String clientLANAwaitDescription() {
		if(clientDescription != null) {
			String ret = clientDescription;
			clientDescription = null;
			return ret;
		}else {
			return null;
		}
	}

	public static boolean clientLANAwaitChannel() {
		if(clientDataChannelOpen) {
			clientDataChannelOpen = false;
			return true;
		}else {
			return false;
		}
	}

	public static boolean clientLANClosed() {
		return clientDataChannelClosed;
	}

	public static void clientLANSetICECandidate(String candidate) {
		rtcLANClient.signalRemoteICECandidate(candidate);
	}

	public static void clientLANSetDescription(String description) {
		rtcLANClient.signalRemoteDescription(description);
	}

	private static LANServer rtcLANServer = null;

	public static void startRTCLANServer() {
		if (rtcLANServer == null) {
			rtcLANServer = new LANServer();
		}
	}

	private static final Map<String, List<LANPeerEvent>> serverLANEventBuffer = new HashMap<>();

	private static void addServerLANEvent(String peerId, LANPeerEvent event) {
		synchronized(serverLANEventBuffer) {
			serverLANEventBuffer.computeIfAbsent(peerId, ignored -> new LinkedList<>()).add(event);
		}
	}

	public static void serverLANInitializeServer(String[] servers) {
		synchronized(serverLANEventBuffer) {
			serverLANEventBuffer.clear();
		}
		rtcLANServer.setIceServers(servers);
	}

	public static void serverLANCloseServer() {
		rtcLANServer.signalRemoteDisconnect("");
		synchronized(serverLANEventBuffer) {
			serverLANEventBuffer.clear();
		}
	}

	public static LANPeerEvent serverLANGetEvent(String clientId) {
		synchronized(serverLANEventBuffer) {
			if(!serverLANEventBuffer.isEmpty()) {
				List<LANPeerEvent> l = serverLANEventBuffer.get(clientId);
				if(l != null && !l.isEmpty()) {
					LANPeerEvent event = l.remove(0);
					if(l.isEmpty()) {
						serverLANEventBuffer.remove(clientId);
					}
					return event;
				}
			}
			return null;
		}
	}

	public static List<LANPeerEvent> serverLANGetAllEvent(String clientId) {
		synchronized(serverLANEventBuffer) {
			if(!serverLANEventBuffer.isEmpty()) {
				List<LANPeerEvent> l = serverLANEventBuffer.remove(clientId);
				if(l == null || l.isEmpty()) {
					return null;
				}
				return l;
			}
			return null;
		}
	}

	public static void serverLANWritePacket(String peer, byte[] data) {
		rtcLANServer.sendPacketToRemoteClient(peer, TeaVMUtils.unwrapArrayBuffer(data));
	}

	public static int serverLANPeerBufferedAmount(String peer) {
		if(rtcLANServer == null) {
			return 0;
		}
		LANPeer lanPeer = rtcLANServer.peerList.get(peer);
		return lanPeer != null && lanPeer.dataChannel != null ? getBufferedAmount(lanPeer.dataChannel) : 0;
	}

	public static void serverLANCreatePeer(String peer) {
		rtcLANServer.signalRemoteConnect(peer);
	}

	public static void serverLANPeerICECandidates(String peer, String iceCandidates) {
		rtcLANServer.signalRemoteICECandidate(peer, iceCandidates);
	}

	public static void serverLANPeerDescription(String peer, String description) {
		rtcLANServer.signalRemoteDescription(peer, description);
	}

	public static void serverLANPeerMapIPC(String peer, String ipcChannel) {
		rtcLANServer.serverPeerMapIPC(peer, ipcChannel);
	}

	public static boolean serverLANPeerPassIPC(String channelName, ArrayBuffer data) {
		if(rtcLANServer != null) {
			LANPeer peer = rtcLANServer.ipcMapList.get(channelName);
			if(peer != null) {
				rtcLANServer.sendPacketToRemoteClient(peer, data);
				return true;
			}else {
				return false;
			}
		}else {
			return false;
		}
	}

	public static void serverLANDisconnectPeer(String peer) {
		rtcLANServer.signalRemoteDisconnect(peer);
	}

	public static int countPeers() {
		if (rtcLANServer == null) {
			return 0;
		}
		return rtcLANServer.countPeers();
	}

}
