/*
 * Copyright (c) 2014 castLabs GmbH
 *
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/.
 */

package com.castlabs.dash.loaders {
import com.castlabs.dash.boxes.FLVTag;
import com.castlabs.dash.boxes.Mixer;
import com.castlabs.dash.descriptors.Representation;
import com.castlabs.dash.descriptors.segments.MediaDataSegment;
import com.castlabs.dash.descriptors.segments.Segment;
import com.castlabs.dash.events.FragmentEvent;
import com.castlabs.dash.events.SegmentEvent;
import com.castlabs.dash.events.StreamEvent;
import com.castlabs.dash.handlers.AudioSegmentHandler;
import com.castlabs.dash.handlers.InitializationAudioSegmentHandler;
import com.castlabs.dash.handlers.InitializationSegmentHandler;
import com.castlabs.dash.handlers.InitializationVideoSegmentHandler;
import com.castlabs.dash.handlers.ManifestHandler;
import com.castlabs.dash.handlers.MediaSegmentHandler;
import com.castlabs.dash.handlers.VideoSegmentHandler;
import com.castlabs.dash.utils.AdaptiveSegmentIterator;
import com.castlabs.dash.utils.BandwidthMonitor;

import flash.events.EventDispatcher;
import flash.utils.ByteArray;
import flash.utils.Dictionary;

public class FragmentLoader extends EventDispatcher {
    private var _manifest:ManifestHandler;
    private var _iterator:AdaptiveSegmentIterator;
    private var _monitor:BandwidthMonitor;
    private var _mixer:Mixer;

    private var _initializationSegmentHandlers:Dictionary = new Dictionary();
    private var _indexSegmentFlags:Dictionary = new Dictionary();

    private var _audioSegmentHandler:MediaSegmentHandler;
    private var _videoSegmentHandler:MediaSegmentHandler;

    private var _audioSegmentLoaded:Boolean = false;
    private var _videoSegmentLoaded:Boolean = false;

    private var _audioSegmentLoader:SegmentLoader;
    private var _videoSegmentLoader:SegmentLoader;

    private var _audioSegment:MediaDataSegment;
    private var _videoSegment:MediaDataSegment;

    private var _audioOffset:Number = 0;
    private var _videoOffset:Number = 0;

    public function FragmentLoader(manifest:ManifestHandler, iterator:AdaptiveSegmentIterator,
                                   monitor:BandwidthMonitor, mixer:Mixer) {
       _manifest = manifest;
       _iterator = iterator;
       _monitor = monitor;
       _mixer = mixer;
    }

    public function init():void {
        loadInitializationSegments(_manifest.audioRepresentations, onInitializationAudioSegmentLoaded);
        loadInitializationSegments(_manifest.videoRepresentations, onInitializationVideoSegmentLoaded);

        loadIndexSegments(_manifest.audioRepresentations, onIndexSegmentLoaded);
        loadIndexSegments(_manifest.videoRepresentations, onIndexSegmentLoaded);
    }

    public function seek(timestamp:Number):Number {
        close();

        _audioSegment = MediaDataSegment(_iterator.getAudioSegment(timestamp));
        _videoSegment = MediaDataSegment(_iterator.getVideoSegment(timestamp));

        _audioOffset = _audioSegment.startTimestamp;
        _videoOffset = _videoSegment.startTimestamp;

        trace("Seek to audio segment: " + _audioSegment);
        trace("Seek to video segment: " + _videoSegment);

        return _videoSegment.startTimestamp; // offset
    }

    public function loadFirstFragment():void {
        _audioSegmentLoader = loadSegment(_audioSegment, onAudioSegmentLoaded);
        _videoSegmentLoader = loadSegment(_videoSegment, onVideoSegmentLoaded);
    }

    public function loadNextFragment():void {
        if (_videoSegment.endTimestamp < _audioSegment.endTimestamp) {
            _videoSegmentLoaded = false;
            _audioSegmentLoaded = true;
        }

        if (_videoSegment.endTimestamp > _audioSegment.endTimestamp) {
            _videoSegmentLoaded = true;
            _audioSegmentLoaded = false;
        }

        if (_videoSegment.endTimestamp == _audioSegment.endTimestamp) {
            _videoSegmentLoaded = false;
            _audioSegmentLoaded = false;
        }

        if (!_audioSegmentLoaded) {
            _audioSegment = MediaDataSegment(_iterator.getAudioSegment(_audioSegment.endTimestamp));
        }

        if (!_videoSegmentLoaded) {
            _videoSegment = MediaDataSegment(_iterator.getVideoSegment(_videoSegment.endTimestamp));
        }

        if (!_audioSegment || !_videoSegment) { // notify end
            dispatchEvent(new StreamEvent(StreamEvent.END));
            reset();
            return;
        }

        if (!_audioSegmentLoaded) {
            trace("Next audio segment: " + _audioSegment);
            _audioSegmentLoader = loadSegment(_audioSegment, onAudioSegmentLoaded);
        }

        if (!_videoSegmentLoaded) {
            trace("Next video segment: " + _videoSegment);
            _videoSegmentLoader = loadSegment(_videoSegment, onVideoSegmentLoaded);
        }
    }

    public function close():void {
        if (_audioSegmentLoader != null) {
            _audioSegmentLoader.close();
        }

        if (_videoSegmentLoader != null) {
            _videoSegmentLoader.close();
        }

        reset();
    }

    private function onInitializationAudioSegmentLoaded(event:SegmentEvent):void {
        _initializationSegmentHandlers[event.segment.internalRepresentationId] =
                new InitializationAudioSegmentHandler(event.bytes);
        notifyReadyIfNeeded();
    }

    private function onInitializationVideoSegmentLoaded(event:SegmentEvent):void {
        _initializationSegmentHandlers[event.segment.internalRepresentationId] =
                new InitializationVideoSegmentHandler(event.bytes);
        notifyReadyIfNeeded();
    }

    private function onIndexSegmentLoaded(event:SegmentEvent):void {
        _indexSegmentFlags[event.segment.internalRepresentationId] = true;
        notifyReadyIfNeeded();
    }

    private function loadInitializationSegments(representations:Vector.<Representation>, callback:Function):void {
        for each (var representation:Representation in representations) {
            var segment:Segment = representation.getInitializationSegment();
            loadSegment(segment, callback);
        }
    }

    private function loadIndexSegments(representations:Vector.<Representation>, callback:Function):void {
        for each (var representation:Representation in representations) {
            var segment:Segment = representation.getIndexSegment();
            loadSegment(segment, callback);
        }
    }

    private function notifyReadyIfNeeded():void {
        var expectedLength:Number = _manifest.audioRepresentations.length + _manifest.videoRepresentations.length;
        var initializationSegmentsLoaded:Boolean = getLength(_initializationSegmentHandlers) == expectedLength;
        var indexSegmentsLoaded:Boolean = getLength(_indexSegmentFlags) == expectedLength;

        if (initializationSegmentsLoaded && indexSegmentsLoaded) {
            dispatchEvent(new StreamEvent(StreamEvent.READY, false, false, { duration: _manifest.duration }));
        }
    }

    public static function getLength(dict:Dictionary):Number {
        var n:int = 0;

        for (var key:* in dict) {
            n++;
        }

        return n;
    }

    private function onAudioSegmentLoaded(event:SegmentEvent):void {
        var _initializationSegmentHandler:InitializationSegmentHandler =
                _initializationSegmentHandlers[event.segment.internalRepresentationId];

        var offset:Number = findSmallerOffset();

        _audioSegmentHandler = new AudioSegmentHandler(event.bytes, _initializationSegmentHandler.messages,
                _initializationSegmentHandler.defaultSampleDuration, _initializationSegmentHandler.timescale,
                (_audioSegment.startTimestamp - offset) * 1000, _mixer);

        _audioSegmentLoaded = true;

        notifyLoadedIfNeeded();
    }

    private function onVideoSegmentLoaded(event:SegmentEvent):void {
        var _initializationSegmentHandler:InitializationSegmentHandler =
                _initializationSegmentHandlers[event.segment.internalRepresentationId];

        var offset:Number = findSmallerOffset();

        _videoSegmentHandler = new VideoSegmentHandler(event.bytes, _initializationSegmentHandler.messages,
                _initializationSegmentHandler.defaultSampleDuration, _initializationSegmentHandler.timescale,
                (_videoSegment.startTimestamp - offset) * 1000, _mixer);

        _videoSegmentLoaded = true;

        notifyLoadedIfNeeded();
    }

    private function findSmallerOffset():Number {
        if (_videoOffset <= _audioOffset) {
            return _videoOffset;
        } else  {
            return _audioOffset;
        }
    }

    private function loadSegment(segment:Segment, callback:Function):SegmentLoader {
        var loader:SegmentLoader = SegmentLoaderFactory.create(segment, _monitor);
        loader.addEventListener(SegmentEvent.LOADED, callback);
        loader.load();
        return loader;
    }

    private function notifyLoadedIfNeeded():void {
        if (_audioSegmentLoaded && _videoSegmentLoaded) {
            var bytes:ByteArray = new ByteArray();

            // _audioSegmentHandler is null if not loaded
            if (_audioSegmentHandler != null) {
                bytes.writeBytes(_audioSegmentHandler.bytes);
            }

            // _videoSegmentHandler is null if not loaded
            if (_videoSegmentHandler != null) {
                bytes.writeBytes(_videoSegmentHandler.bytes);
            }

            _audioSegmentLoaded = false;
            _videoSegmentLoaded = false;

            _audioSegmentHandler = null;
            _videoSegmentHandler = null;

            var endTimestamp:Number;

            if (_videoSegment.endTimestamp <= _audioSegment.endTimestamp) {
                endTimestamp = _videoSegment.endTimestamp;
            }

            if (_videoSegment.endTimestamp > _audioSegment.endTimestamp) {
                endTimestamp = _audioSegment.endTimestamp;
            }

            dispatchEvent(new FragmentEvent(FragmentEvent.LOADED, false, false, bytes, endTimestamp)); // startTimestamp
        }
    }

    private function reset():void {
        _audioSegmentLoader = null;
        _videoSegmentLoader = null;

        _audioSegmentHandler = null;
        _videoSegmentHandler = null;

        _audioSegmentLoaded = false;
        _videoSegmentLoaded = false;
    }
}
}