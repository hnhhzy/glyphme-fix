package glyphme;

import h2d.Font;
import h2d.Tile;
import hxd.Pixels;
import h2d.Font.FontChar;
import glyphme.GlyphMe;

/** Pass this to h2d.Text etc. Right now this doesn't support dynamic glyph generation 
 * so before displaying any text you have to prepare an atlas of the glyphs you might want
 * to display, see generateAtlas(). It somewhat supports using consecutive fallback TrueTypeFontInfos 
 * to look up glyphs that it couldn't find in the previous TrueTypeFontInfo (when generating atlas). */
class TrueTypeFont extends h2d.Font {
	public var infos:Array<TrueTypeFontInfo>;

	public var scaleMode:TrueTypeFontScaleMode = Ascent;

	// layout related, these will be calculated
	public var ascent:Float;
	public var descent:Float;
	public var lineGap:Float;
	public var lastGenerationParameters:TrueTypeFontGenerationParameters;

	public function new(infos:Array<TrueTypeFontInfo>, sizeInPixels:Int, alphaCutOff:Float, smoothing:Float) {
		this.infos = infos;

		final first = infos[0];

		final scale = getScaleForPixelHeight(first, sizeInPixels);

		ascent = first.ascent * scale;
		descent = first.descent * scale;
		lineGap = first.lineGap * scale;

		super(null, sizeInPixels, h2d.Font.FontType.SignedDistanceField(Red, alphaCutOff, smoothing));

		super.lineHeight = sizeInPixels;
		super.baseLine = ascent;
		super.tile = @:privateAccess new Tile(null, 0, 0, 0, 0); // to avoid null access
	}
	
	private var __forceHasChar:Bool = false;

	override function hasChar(code:Int):Bool {
		if(code == Key.BACKSPACE) return false;
		if(Key.isDown(Key.CTRL)) return false;
		if (__forceHasChar)
			return true;
		return super.hasChar(code);
	}

	/** Fallbacks are used to look up glyphs from multiple fonts. When a glyph is not found
	 * we try the next font. If you have multiple fallbacks with slightly overlapping glyph support
	 * this might result in weird looking text, since we always stop at the first one found. 
	 * Also scale, line height ascent, descent are controlled by the first info. */
	public function addFallback(info:TrueTypeFontInfo) {
		infos.push(info);
	}

	/** Fallbacks are used to look up glyphs from multiple fonts. When a glyph is not found
	 * we try the next font. If you have multiple fallbacks with slightly overlapping glyph support
	 * this might result in weird looking text, since we always stop at the first one found. 
	 * Also scale, line height ascent, descent are controlled by the first info. */
	public function addFallbacks(infos:Array<TrueTypeFontInfo>) {
		for (info in infos)
			addFallback(info);
	}

	/** Generates an atlas of glyphs for all code points in given input strings.
	 * Overrides the previous atlas. If you're just using this to display 
	 * static text (which is what this was meant for) you can just pass the text
	 * directly. If parameters == null, the last used parameters are used 
	 * Useful if you want to keep font size and all that but need to display 
	 * a different set of stings). 
	 * This function is pretty slow with large amounts of input but it 
	 * should work when calling from a background thread... but I don't know 
	 * anything about thread safety. */
	public function generateAtlas(parameters:TrueTypeFontGenerationParameters, strings:Array<String>) {
		if (parameters == null) {
			if (lastGenerationParameters == null)
				throw new haxe.Exception('Could not regenerate atlas with the current generation parameters because they are null.');
			parameters = lastGenerationParameters;
		}

		// adjusting scale in case we generate at a different size
		final ratio = size / parameters.fontHeightInPixels;

		glyphs.clear();
		final pack:Array<{
			char:FontChar,
			g:TrueTypeFontGlyphInfo,
			packed:Bool
		}> = [];

		strings.unshift(parameters.unresolvedChar + "?"); // always generate this
		for (string in strings) {
			for (stringIndex in 0...string.length) {
				final code = string.charCodeAt(stringIndex);

				var g:TrueTypeFontGlyphInfo = null;
				for (info in infos) {
					if (glyphs[code] != null) // skip duplicates
						continue;

					g = generateGlyph(code, info, parameters);
					if (g != null) {
						final char = new TrueTypeFontChar(this, g.fontInfo, g.index, defaultChar.t, g.advanceX * ratio);
						glyphs[g.codePoint] = char;

						// space bar for example has no pixels, but still has advanceX
						// so we have to add it to glyphs but theres no need to pack it
						// HELP: space bar seems to work but tab (\t) has no effect on the output
						if (g.rgba != null)
							pack.push({
								char: char,
								g: g,
								packed: false
							});

						break;
					}
				}
			}
		}

		// replacing unresolved
		var unresolvedCode = parameters.unresolvedChar.charCodeAt(0);
		if (glyphs[unresolvedCode] == null) {
			trace('Could not resolve unresolvedChar ${parameters.unresolvedChar}, using "?" instead. Choose one you are sure is resolvable or add a fallback. ');
			unresolvedCode = "?".code;
		}

		for (string in strings) {
			for (stringIndex in 0...string.length) {
				final code = string.charCodeAt(stringIndex);
				if (glyphs[code] == null && code != "\t".code && code != "\r".code && code != "\n".code && glyphs[code] == null)
					glyphs[code] = glyphs[unresolvedCode];
			}
		}

		final length = pack.length;

		pack.sort((c1, c2) -> c2.g.height - c1.g.height); // sorting tall to small

		// row packing the glyphs and drawing to atlas
		var atlas:Pixels;
		var brush = new Pixels(0, 0, null, RGBA);

		// returns the number of glyphs this function call packed
		function tryToPack(index:Int, originX:Int, originY:Int, bounds:Int) {
			final atlasSize = parameters.atlasSize;

			var numberPacked = 0;
			var x = originX;
			var y = originY;
			var maxHeightThisRow = 0;
			while (index < length) {
				final element = pack[index];
				if (element.packed) {
					index++;
					continue;
				}

				final g = element.g;
				final width = g.width, height = g.height;

				if (y + height > originY + bounds) {
					break;
				} else if (x + width > atlasSize) {
					if (maxHeightThisRow == 0)
						break;
					// scanning ahead for a thinner character that isn't already packed
					// and start packing from there again to maybe squeeze in one or more characters
					var squeezeIndex = index;
					while (++squeezeIndex < length) {
						final number = tryToPack(squeezeIndex, x, y, height);
						numberPacked += number;
						if (number != 0)
							break;
					}

					x = originX;
					y += maxHeightThisRow;
					maxHeightThisRow = 0;
				} else {
					if (height > maxHeightThisRow)
						maxHeightThisRow = height;

					final dx = g.offsetX * ratio;
					final dy = (g.offsetY + ascent / ratio) * ratio;
					final t = tile.sub(x, y, width, height, dx, dy);
					t.scaleToSize(ratio * width, ratio * height);

					final char = glyphs[g.codePoint];
					char.t = t;

					// drawing and creating char tile
					@:privateAccess {
						brush.width = width;
						brush.height = height;
						brush.bytes = g.rgba.toBytes(width * height * 4);
					}
					atlas.blit(x, y, brush, 0, 0, width, height);

					element.packed = true;

					x += width;
					index++;
					numberPacked++;
				}
			}

			#if glyphme.drawPack
			if (numberPacked != 0)
				drawPack(atlas, originX, originY, atlasSize - originX, bounds);
			#end

			return numberPacked;
		}

		while (true) {
			final atlasSize = parameters.atlasSize;

			atlas = Pixels.alloc(atlasSize, atlasSize, RGBA);
			tile = Tile.fromPixels(atlas);

			final numberPacked = tryToPack(0, 0, 0, atlasSize);
			final numberNotPacked = length - numberPacked;

			for (e in pack)
				e.packed = false;

			if (numberNotPacked != 0) {
				if (parameters.autoFit) {
					parameters.atlasSize *= 2;
					continue;
				} else {
					throw new haxe.Exception('Couldn\'t pack $numberNotPacked glyphs for font: $name, please increase atlasSize or enable autoFit.');
				}
			}

			break;
		}

		tile.getTexture().uploadPixels(atlas);
		lastGenerationParameters = parameters;
	}

	public override function clone():Font {
		final f = new TrueTypeFont(infos.copy(), size, 0, 0);
		f.baseLine = baseLine;
		f.lineHeight = lineHeight;
		f.tile = tile.clone();
		f.charset = charset;
		f.defaultChar = defaultChar.clone();
		f.type = type;
		for (g in glyphs.keys()) {
			var c = glyphs.get(g);
			var c2 = c.clone();
			if (c == defaultChar)
				f.defaultChar = c2;
			f.glyphs.set(g, c2);
		}

		f.infos = infos.copy();
		f.scaleMode = scaleMode;
		f.ascent = ascent;
		f.descent = descent;
		f.lineGap = lineGap;
		f.lastGenerationParameters = lastGenerationParameters;

		return f;
	}

	public override function resizeTo(size:Int) {
		final ratio = size / initSize;
		super.resizeTo(size);
		ascent = ascent * ratio;
		descent = descent * ratio;
		lineGap = lineGap * ratio;
	}

	function generateGlyph(code:Int, info:TrueTypeFontInfo, p:TrueTypeFontGenerationParameters):TrueTypeFontGlyphInfo {
		final scale = getScaleForPixelHeight(info, p.fontHeightInPixels);
		final g:TrueTypeFontGlyphInfo = cast GlyphMeNative.getGlyph(code, info.stbttFontInfo, scale, p.padding, p.onEdgeValue, p.pixelDistScale);
		if (g != null)
			g.fontInfo = info;

		return g;
	}

	public inline function getScaleForPixelHeight(info:TrueTypeFontInfo, height:Float) {
		return switch (scaleMode) {
			case Ascent:
				height / ( info.ascent - info.descent);
			case AscentAndDescent:
				height / (info.ascent + info.descent);
			case Custom(getScale):
				return getScale(info, height);
		}
	}

	@:noCompletion
	function drawPack(atlas:Pixels, x:Int, y:Int, w:Int, h:Int) {
		final color = new h3d.Vector(1, 0, 0, 1).toColor();
		final thickness = 3;
		for (t in 0...thickness) {
			for (xl in 0...w)
				atlas.setPixel(x + xl, y + t, color);
			for (yl in 0...h)
				atlas.setPixel(x + t, y + yl, color);
		}
	}
}

class TrueTypeFontChar extends h2d.Font.FontChar {
	public var font:TrueTypeFont;
	public var fontInfo:TrueTypeFontInfo;
	public var index:Int;

	public function new(font, fontInfo, index, t, w) {
		this.font = font;
		this.fontInfo = fontInfo;
		this.index = index;

		super(t, w);
	}

	public override function getKerningOffset(prevChar:Int):Float {
		final previous:TrueTypeFontChar = cast @:privateAccess font.glyphs[prevChar];
		if (previous == null)
			return 0;

		final scale = font.getScaleForPixelHeight(fontInfo, font.size);
		final unscaled = GlyphMeNative.getKerning(fontInfo.stbttFontInfo, previous.index, index);

		return unscaled * scale + super.getKerningOffset(prevChar); // i don't know if the super call is relevant?
	}
}

typedef TrueTypeFontGlyphInfo = GlyphInfo & {fontInfo:TrueTypeFontInfo}

@:structInit
class TrueTypeFontGenerationParameters {
	/** character to use instead if the glyph cannot be resolved */
	public var unresolvedChar = "?";

	/** If true, will double atlasSize until all glyphs fit. (SLOW) **/
	public var autoFit = true;

	/** the width and height of the atlas on which glyphs will be generated. . */
	public var atlasSize = 1024;

	public var fontHeightInPixels:Int;

	/** extra pixels around the character which are filled with the distance to the character (not 0) */
	public var padding:Int = 2;

	/** value 0-255 to test the SDF against to reconstruct the character (i.e. the isocontour of the character)  */
	public var onEdgeValue:Int = 180;

	/** what value the SDF should increase by when moving one SDF "pixel" away from the edge (on the 0..255 scale)
	 * if positive, > onedge_value is inside; if negative, < onedge_value is inside */
	public var pixelDistScale:Float = 180;
}

/**
 * Choose how you want to define scale. I think heaps normally uses Ascent (how much the characters ascend above the baseline).
 * Or you could define it to include descent as well, stbtt does this by default. And I think it works better when using fallbacks as well.
 */
enum TrueTypeFontScaleMode {
	/**
	 * sizeInPixels / ascent;
	 */
	Ascent;

	/**
	 * sizeInPixels / (ascent + descent); ---(descent is negative)
	 */
	AscentAndDescent;

	/**
	 * Allows you to implement a custom scale function. For example AscentAndDescent is implemented as:
	 * return sizeInPixels / (ascent + descent); ---(descent is negative)
	 */
	Custom(getScale:(fontInfo:TrueTypeFontInfo, sizeInPixels:Float) -> Float);
}
